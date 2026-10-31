# omarchy-lightning

A Bitcoin Lightning wallet for the [Omarchy](https://omarchy.org) bar, built on the [Lexe](https://lexe.app) SDK.

A bolt icon sits in the bar with your balance beside it. Click it to fund the wallet (invoice shown as a QR code) or, once there is a balance, to pay any invoice, BOLT 12 offer, on-chain address, or Lightning address.

> ## ⚠️ Experimental software. Use only money you can afford to lose.
>
> This is an early, unaudited v0.x release written quickly and tested by one person. It manages a real **mainnet** Bitcoin wallet. Bugs can lose funds. Do not put in more than you would be comfortable losing, and read the limitations below before you do.

## Install

```sh
omarchy plugin add https://github.com/matbalez/omarchy-lightning.git --enable
```

Requires `qrencode` (already present on a standard Omarchy install), `wl-clipboard`, and Python 3.10+. On first use the plugin creates a private virtualenv in `~/.local/share/omarchy-lightning` and installs the [`lexe-sdk`](https://pypi.org/project/lexe-sdk/) package from PyPI into it.

Update with `omarchy plugin update omarchy-lightning`; remove with `omarchy plugin remove omarchy-lightning`. QML changes need `omarchy-restart-shell` to take effect.

## How it works

- **First click creates your wallet.** Opening the popup for the first time generates a new root seed, saves it, and signs you up with Lexe, which runs a Lightning node for you in the cloud. Nothing is created until you click the bolt.
- **Funding** creates a Lightning invoice shown as a QR code. The popup polls for the payment and updates the balance when it arrives.
- **Sending** takes a destination and an amount (the amount is ignored if the invoice already contains one) and pays immediately, then polls until the payment confirms.
- Amounts are shown in sats with the bitcoin sign, e.g. `₿1,000`.

The popup talks only to `bin/omarchy-lightning`, a small Python script that prints JSON. The seed and the SDK never enter the shell process.

## Limitations and risks: please read

- **Your recovery phrase is your wallet.** It is stored as plain text in `~/.lexe/seedphrase.txt` (mode 600). Anyone with that file can spend your funds; if you lose it and your disk dies, so do your funds. **There is no backup screen yet.** After creating the wallet, run `~/.config/omarchy/plugins/omarchy-lightning/bin/omarchy-lightning seed` and write the words down offline.
- **Plugins are unsandboxed.** Omarchy runs plugin QML inside the long-lived shell with your full user permissions. Read the code (it is small) before enabling it.
- **Supply chain.** First run downloads `lexe-sdk` from PyPI, pinned to `>=0.1.23,<0.2`.
- **Trusting Lexe.** The node runs on Lexe's infrastructure inside secure hardware (SGX). You are trusting that design and Lexe's service availability; see [Lexe's docs](https://docs.lexe.tech). This project is not affiliated with Lexe.
- **Mainnet only, no testnet switch.** One wallet per user account.
- **Unreviewed code paths.** Payments to on-chain addresses, BOLT 12 offers, LNURL and Lightning addresses go through the SDK's generic `pay` call and have had little real-world testing.
- Error messages are mostly Lexe's own wording.
- Only English strings; no history screen; no way to restore from a seed through the UI.

## Files

| File | Purpose |
| --- | --- |
| `manifest.json` | Omarchy plugin manifest (`bar-widget`) |
| `Panel.qml` | Bar button and popup UI |
| `bin/omarchy-lightning` | Backend CLI: `status`, `setup`, `invoice`, `analyze`, `pay`, `payment`, `seed` |

## License

[MIT](LICENSE). The Lexe SDK is a separate MIT-licensed package, installed at runtime and not redistributed here.
