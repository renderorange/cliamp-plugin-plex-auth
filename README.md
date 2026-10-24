# cliamp-plugin-plex-auth

A [cliamp](https://github.com/bjarneo/cliamp) plugin that signs you in to Plex. You get a 4-character code, enter it at [plex.tv/link](https://plex.tv/link), and the plugin puts your server's address and the token it expects in the `[plex]` section of cliamp's config.

Sign in once and cliamp opens your Plex library on every start after that, the same as your Apple or Google TV. It can also play as a Plex Home profile instead of the account owner.

## How it works

Signing in gives the plugin a token for your Plex account, which it keeps in its own store. On every start it checks with plex.tv that the token still works, switches to your profile if you set one, and asks which servers that account or profile can use, and which token each expects. Then it rewrites `url` and `token` in `[plex]` if they differ.

| What happens | What the plugin does |
|---|---|
| `[plex]` is already right | Nothing. You won't notice it's there. |
| `[plex]` needs a new address or token | Updates it, then says whether to restart or to run one `mv` first — see [Applying the change](#applying-the-change) |
| You haven't signed in, or plex.tv rejects the account token | Shows a 4-character code in the status bar and as a desktop notification |
| plex.tv doesn't answer (no network, or it's down) | Leaves `[plex]` alone and writes a note to the log |
| A setting is wrong, such as a profile that doesn't exist | Says what's wrong in the status bar and leaves `[plex]` alone |

Only the `url` and `token` lines change, and they keep their spacing. Everything else in `config.toml` stays as it was, apart from a comment on the end of those two lines, which is dropped.

The code lasts 15 minutes; if it runs out, run `cliamp plugins call plex-auth signin`. Tokens don't expire on a schedule — your Apple TV stays signed in because it saved its token once, and this plugin does the same. A token stops working only when it's revoked, by **Sign out of all devices** or by removing the `cliamp` device under **Settings → Authorized Devices**. The next start then gives you a new code.

### Applying the change

cliamp connects to Plex once, at startup, before any plugin runs, so a plugin can't hand it a new address or token afterwards. An update to `[plex]` therefore needs a restart.

cliamp builds after v2.3.0 also refuse to let a plugin write `config.toml`, so that a plugin can't approve its own code. When that write is refused, the plugin leaves the finished file at `config.toml.new` beside your config and shows the command that swaps it in:

```bash
mv ~/.config/cliamp/config.toml.new ~/.config/cliamp/config.toml
```

It is your config with only the `url` and `token` lines changed, so nothing else is lost, and `mv` replaces it in one step. Run it, then restart cliamp. On cliamp v2.3.0 and earlier the plugin writes `config.toml` itself and there is nothing to run.

A normal start changes nothing, because the tokens a server expects stay the same from one start to the next.

### The server address

Plex servers use a certificate for an address ending in `plex.direct`, such as `https://11-22-222-222.<id>.plex.direct:32400`. If `[plex]` holds another name for the same server, such as your own domain, cliamp refuses the connection because the certificate doesn't match; Plex Web works because it uses the `plex.direct` address.

The plugin picks the address like this:

1. If the `url` already in `[plex]` is one of the server's addresses, it stays. So if you switch to the home-network address yourself, the plugin leaves it alone.
2. Otherwise it uses the server's direct internet address, which works both at home and away.
3. Failing that, the home-network address, and Plex's relay only as a last resort — the relay is slow and limits the bitrate.

Servers your friends share with you show up too. When there's more than one, the plugin uses the one your account owns; if that still leaves more than one, the status bar tells you to pick one with the `server` setting, and lists their names.

## Install

You need cliamp and a Plex Media Server. The plugin uses only cliamp's built-in Lua functions, so there's nothing else to install.

1. Copy it into cliamp's plugins folder, creating it if needed:

   ```bash
   mkdir -p ~/.config/cliamp/plugins
   cp plex-auth.lua ~/.config/cliamp/plugins/
   ```

2. Approve it — cliamp runs a plugin only after you approve its exact contents:

   ```bash
   cliamp plugins trust plex-auth
   ```

3. Start cliamp and enter the code at plex.tv/link. Then do what the status bar says: run the `mv` it shows, if it shows one, and restart cliamp. There's no `[plex]` section to add and no address to look up; the plugin works out both.

If you edit `plex-auth.lua`, copy it again and run `cliamp plugins trust plex-auth` again: cliamp turns off any plugin whose contents changed since you approved it.

## Settings

Both are optional:

```toml
[plugins.plex-auth]
profile = "blaine"
server = "sol"
```

| Setting | What it does |
|---|---|
| `profile` | The Plex Home profile cliamp plays as. Leave it out to play as the account owner. Profiles with a PIN aren't supported yet. |
| `server` | The server to use, by the name Plex shows for it. Only needed when the plugin can't tell which server you mean. |

Change either one and restart cliamp twice: once so the plugin reads the setting and updates `[plex]`, and once more so cliamp loads it.

Playlists belong to each profile, so switching profiles shows that profile's playlists, not the owner's.

## Commands

While cliamp is running:

```bash
cliamp plugins call plex-auth status     # signed in? which profile? which address?
cliamp plugins call plex-auth profiles   # list your Plex Home profiles
cliamp plugins call plex-auth signin     # sign in again with a new code
```

`status`:

```
Signed in to plex.tv.
Profile: blaine
Server address: https://11-22-222-222.1aa39484d8a64e8099f5fe044b9630f.plex.direct:32400
```

When an `mv` is waiting, `status` adds the command to run.

`profiles` prints the names to use in `profile`:

```
renderorange (account owner)
blaine (managed)
sweetest wuppies (managed)
```

`signin` prints the code too, so you can start a sign-in from another terminal.

## What it shows in Plex

Under **Settings → Authorized Devices** the plugin shows up as `cliamp`, with your computer's name from `/etc/hostname`. It makes an app ID on first run and reuses it, because Plex lists every app ID as a separate device — without that, each sign-in would add another `cliamp`, and before long you'd own 40 identical laptops.

## Files it uses

| File | What's in it |
|---|---|
| `~/.config/cliamp/config.toml` | `url` and `token` in `[plex]`, which the plugin reads and writes, plus its own settings in `[plugins.plex-auth]`. |
| `~/.config/cliamp/config.toml.new` | The finished config, waiting for the `mv`. Only appears on cliamp builds that refuse the write. |
| `~/.local/share/cliamp/plugins/plex-auth/store.json` | Your account token and the plugin's app ID. |
| `~/.config/cliamp/plugins.log` | Messages from the plugin, each line tagged `[plex-auth]`. |

`CLIAMP_CONFIG_DIR` and `XDG_CONFIG_HOME` are honoured, so the plugin finds `config.toml` where cliamp does.

## Troubleshooting

**No code appeared, and Plex isn't working.** Check that `cliamp plugins list` says `trusted` for `plex-auth`, then look for `[plex-auth]` lines in `~/.config/cliamp/plugins.log`.

**I entered the code, but Plex still isn't there.** Do what the status bar says: run the `mv`, if it shows one, then restart cliamp. See [Applying the change](#applying-the-change).

**The status bar shows an `mv` command.** cliamp builds after v2.3.0 won't let a plugin write `config.toml`, so the plugin prepared the file instead. Run the command it shows and restart cliamp; there's nothing to copy or edit by hand.

**A certificate error when cliamp connects.** The `url` in `[plex]` isn't a `plex.direct` address. Delete the `url` line and restart cliamp; the plugin works out the right one, and you run the `mv` it shows, if any. Then restart once more.

**Plex loads, but my playlists are missing.** You're playing as a profile, and the playlists belong to another one. Check `profile` under `[plugins.plex-auth]`.

**The status bar says there's more than one Plex server.** Add `server = "<name>"` under `[plugins.plex-auth]`, using one of the names it lists.

**The code expired.** Run `cliamp plugins call plex-auth signin` for a new one.

## Keep the tokens private

Your account token works like your Plex password: anyone with it can use your account, and the token in `[plex]` gives access to your server. Don't commit `config.toml` or `store.json` to git, paste them in a chat or put them in a screenshot.

If one gets out, choose **Sign out of all devices**, which cancels every token including the leaked one, then restart cliamp, enter the new code and restart once more.

The one exception: your friends can have it if they finally return the DVDs they borrowed in 2009.

## Uninstall

```bash
cliamp plugins remove plex-auth
```

Your `[plex]` section stays in `config.toml` and cliamp keeps using it; removing the plugin only means nobody checks it at startup. The store keeps your account token too, so delete it as well if you want it gone:

```bash
rm -r ~/.local/share/cliamp/plugins/plex-auth
```

## Tests

The plugin runs against a stubbed cliamp, so the tests need no cliamp, no network and no config file:

```bash
lua test/plex_auth_test.lua
```
