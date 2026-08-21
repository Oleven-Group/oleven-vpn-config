#!/usr/bin/env bash
# Valida config.json per Oleven VPN.
#
# PERCHE' 'run' E NON 'check': in sing-box `check` valida solo lo SCHEMA e NON risolve i
# riferimenti fra outbound. Un config che cita un tag inesistente (es. un selector/urltest
# che punta a un outbound rimosso) PASSA `check` e poi va in FATAL "dependency not found"
# all'avvio reale — cioe' outage totale della VPN su ogni client, con CI verde.
# Qui ogni modo selezionabile viene REALMENTE avviato: il TUN viene sostituito da un
# inbound mixed (per non richiedere privilegi di rete in CI) e si verifica che il core
# arrivi a regime senza errori fatali.
#
# Uso:  ./tools/validate-config.sh [config.json]
#       SB=/path/to/sing-box ./tools/validate-config.sh
set -uo pipefail

CFG="${1:-config.json}"
SB="${SB:-sing-box}"
# temp RELATIVA di proposito: su Git Bash (Windows) un path MSYS tipo /tmp/... non e'
# risolvibile dal python3/sing-box nativi. Un path relativo funziona sia in CI Linux
# sia in locale su Windows.
TMP="./.validate-tmp.$$"
mkdir -p "$TMP"
trap 'rm -rf "$TMP"' EXIT

command -v "$SB" >/dev/null 2>&1 || [ -x "$SB" ] || { echo "sing-box non trovato (SB=$SB)"; exit 2; }
[ -f "$CFG" ] || { echo "config non trovato: $CFG"; exit 2; }

# Modi selezionabili = membri del selector 'proxy' (cio' che l'utente puo' davvero scegliere),
# derivati dal config stesso: cosi' il gate non invecchia quando i trasporti cambiano.
MODES="$(python3 - "$CFG" <<'PY'
import json,sys
c=json.load(open(sys.argv[1],encoding='utf-8'))
sel=[o for o in c.get('outbounds',[]) if o.get('type')=='selector']
if not sel:
    print("ERRNOSEL"); raise SystemExit
print(" ".join(m for m in sel[0].get('outbounds',[]) if m))
PY
)"
[ "$MODES" = "ERRNOSEL" ] && { echo "FAIL: nessun outbound 'selector' nel config"; exit 1; }
[ -z "$MODES" ] && { echo "FAIL: selector senza membri"; exit 1; }

echo "Modi selezionabili rilevati dal config: $MODES"
echo

fail=0
port=18100
for m in $MODES; do
  # porta DIVERSA per ogni modo: su Windows (e sotto carico su Linux) il socket della
  # prova precedente puo' restare in TIME_WAIT e far fallire il bind, producendo un
  # falso allarme. Un gate che grida al lupo viene ignorato, e allora non protegge piu'.
  port=$((port+1))
  # __MODE__ -> modo, e TUN -> mixed (nessun privilegio richiesto in CI)
  python3 - "$CFG" "$m" "$TMP/c.json" "$port" <<'PY'
import json,sys
raw=open(sys.argv[1],encoding='utf-8').read().replace('__MODE__', sys.argv[2])
c=json.loads(raw)
c['inbounds']=[{"type":"mixed","tag":"probe-in","listen":"127.0.0.1","listen_port":int(sys.argv[4])}]
# livello "warn": basta per intercettare i FATAL (che sono piu' severi) e il volume di
# output ridotto evita che il processo di prova termini prematuramente quando lo stdout
# viene rediretto su file (osservato su Windows con log info/debug).
c['log']={"level":"warn","timestamp":False}
json.dump(c, open(sys.argv[3],'w',encoding='utf-8'))
PY

  # 1) schema
  if ! "$SB" check -c "$TMP/c.json" >"$TMP/check.out" 2>&1; then
    echo "FAIL [$m] schema non valido:"; sed 's/^/    /' "$TMP/check.out" | head -5; fail=1; continue
  fi

  # 2) avvio reale: il criterio non e' "il processo sopravvive N secondi" (fragile e
  #    intermittente) ma "il core arriva ad ASCOLTARE": se apre l'inbound, il grafo degli
  #    outbound e' stato risolto e il servizio e' partito davvero.
  "$SB" run -c "$TMP/c.json" >"$TMP/run.out" 2>&1 &
  sbpid=$!
  listening=0
  for _ in 1 2 3 4 5 6 7 8 9 10 11 12; do
    if python3 -c "import socket,sys; s=socket.socket(); s.settimeout(0.6)
try:
    s.connect(('127.0.0.1', $port)); s.close(); sys.exit(0)
except Exception:
    sys.exit(1)" 2>/dev/null; then listening=1; break; fi
    grep -qiE "FATAL" "$TMP/run.out" 2>/dev/null && break
    kill -0 "$sbpid" 2>/dev/null || break
    sleep 0.5
  done
  kill "$sbpid" 2>/dev/null; wait "$sbpid" 2>/dev/null
  sed -i 's/\[[0-9;]*m//g' "$TMP/run.out" 2>/dev/null || true

  if grep -qiE "FATAL|dependency\[.*\] not found|not found for outbound" "$TMP/run.out"; then
    echo "FAIL [$m] il core non parte:"; grep -iE "FATAL|dependency|not found" "$TMP/run.out" | head -3 | sed 's/^/    /'; fail=1; continue
  fi
  if [ "$listening" -ne 1 ]; then
    echo "FAIL [$m] il core non e' mai arrivato ad ascoltare:"; tail -4 "$TMP/run.out" | sed 's/^/    /'; fail=1; continue
  fi
  echo "OK   [$m] schema valido + core avviato (grafo risolto)"
done

echo
if [ $fail -ne 0 ]; then
  echo "RISULTATO: config NON VALIDO — non pubblicare."
  exit 1
fi

# Invarianti di prodotto imparate da regressioni reali.
python3 - "$CFG" <<'PY'
import json,sys
c=json.load(open(sys.argv[1],encoding='utf-8'))
errs=[]
if '__MODE__' not in open(sys.argv[1],encoding='utf-8').read():
    errs.append("manca il placeholder __MODE__ (i client non potrebbero scegliere il modo)")
for o in c.get('outbounds',[]):
    if o.get('type')=='urltest' and o.get('interrupt_exist_connections') is True:
        errs.append(f"urltest '{o.get('tag')}' ha interrupt_exist_connections=true (causa lo stallo 'va a tratti')")
tun=[i for i in c.get('inbounds',[]) if i.get('type')=='tun']
for t in tun:
    if t.get('mtu',0) > 1400:
        errs.append(f"tun mtu {t.get('mtu')} troppo alto (frammentazione su reti con DPI aggressivo)")
# ogni outbound con un DOMINIO deve avere una via di risoluzione che non passi dal proxy
doms=[o for o in c.get('outbounds',[]) if isinstance(o.get('server'),str) and not o['server'].replace('.','').isdigit()]
if doms:
    dns=c.get('dns',{})
    direct=[s.get('tag') for s in dns.get('servers',[]) if s.get('detour')=='direct']
    rules=dns.get('rules',[])
    resolver=c.get('route',{}).get('default_domain_resolver')
    for o in doms:
        covered = any(o['server'] in (r.get('domain') or []) and r.get('server') in direct for r in rules) or \
                  (isinstance(resolver,dict) and resolver.get('server') in direct)
        if not covered:
            errs.append(f"outbound '{o.get('tag')}' usa il dominio {o['server']} senza DNS diretto: loop di risoluzione (il DNS passerebbe dal proxy non ancora connesso)")
if errs:
    print("RISULTATO: invarianti VIOLATE — non pubblicare.")
    for e in errs: print("  -", e)
    raise SystemExit(1)
print("Invarianti di prodotto: OK (placeholder, interrupt_exist_connections, MTU, risoluzione domini)")
PY
rc=$?
[ $rc -ne 0 ] && exit 1

echo "RISULTATO: config VALIDO per tutti i modi selezionabili."
