# zhist

Forgot to pipe a command's output to a log? `zhist` grabs the previous
command's output from your terminal scrollback and prints it to stdout, so
you can send it wherever you meant to:

```sh
$ zig build          # wall of errors you wish you'd captured
$ zhist >> build.log
$ zhist | wl-copy    # or pbcopy
$ zhist | grep error
```

## Usage

```
zhist              output of the previous command
zhist -n 3         output of the command 3 steps back
zhist -c           include the command line itself
zhist -l           list recent commands
zhist --color      keep ANSI colors (tmux only; stripped by default)
zhist -f <file>    parse a scrollback dump instead (see ghostty below)
zhist --from tmux  force a capture source when tmux/screen are nested
zhist --marker zh  if you invoke zhist through an alias
```

## How it works

A terminal doesn't record where one command's output ends and the next
begins — once a command has run, its output exists only in the terminal's
scrollback. So `zhist` asks the terminal multiplexer for that scrollback:

- **tmux** (`$TMUX`): `tmux capture-pane -p -J -S -`
- **GNU screen** (`$STY`): `screen -X hardcopy -h`
- **anything else**: `-f <file>` with a scrollback dump you provide

It then finds its own invocation line (bottom-most line where the marker
`zhist` follows a prompt character), derives the shape of your prompt from
it, and walks upward matching earlier prompt lines: exact prefix first,
then weaker fallbacks that tolerate prompts embedding a changing cwd or
git branch. The output of command *n* is everything between its prompt
line and the next one.

Set `ZHIST_DEBUG_CAPTURE=/path` to dump the raw capture zhist parsed —
attach it when reporting a misdetected prompt.

## Ghostty

Ghostty has no CLI to read scrollback ([discussion #9804][gh9804]), but it
can dump it to a file on a keybind. In your ghostty config:

```
keybind = ctrl+shift+j=write_scrollback_file:copy
```

That copies the dump's path to the clipboard; then:

```sh
zhist -f "$(wl-paste)"     # linux; pbpaste on macOS
```

Worth wrapping in a tiny shell function. Native support has to wait for
ghostty to grow an IPC surface.

[gh9804]: https://github.com/ghostty-org/ghostty/discussions/9804

## Limitations (honest ones)

- **Heuristic prompt detection.** No multiplexer exposes OSC 133 command
  boundaries through its capture interface, so prompt lines are detected
  by shape. Exotic prompts may need `--marker` or may misdetect; empty
  captures after `clear` are expected (clearing wipes tmux history).
- **Long command lines wrap.** The shell's line editor defeats tmux's
  wrapped-line rejoining (`-J`), so a very long *command line* can leak
  its continuation segments into the reported output. Program *output*
  rejoins fine.
- **stdout and stderr are merged**, because that's what the terminal saw.
- **Output longer than the scrollback buffer is truncated.** Raise
  tmux's `history-limit` if you care.
- Inside screen-inside-tmux (or vice versa), auto-detection prefers tmux;
  use `--from` to override.

## Build

Zig 0.16:

```sh
zig build -Doptimize=ReleaseSafe
zig build test
zig build release   # cross-compile static binaries for all deploy targets
```

`zig build release` drops `zhist-<os>-<arch>` binaries into `zig-out/release/`,
named to match `uname -s`/`uname -m` so a shell alias can pick the right one:

```zsh
alias zh="zhist-$(uname -s | tr '[:upper:]' '[:lower:]')-$(uname -m) --marker zh"
```

`--marker` matters: the terminal scrollback shows the alias you typed, not the
binary's real name, and zhist locates its own invocation line by that text.
