# oleven-vpn-config
Live configuration for the Oleven VPN apps. The apps fetch `config.json` **through the active tunnel** and cache it for the next launch, so servers/params can be rotated without rebuilding. `__MODE__` is the protocol placeholder substituted by the app; Android also swaps the gVisor stack for `system`.
