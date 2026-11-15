<p align="center">
  <img src="Resources/Mark/ReadmeIcon.png" width="96" alt="Athina's app icon: two eyes drawn as one line, with gold irises, on a grey-green field">
</p>
<h1 align="center">Athina</h1>
<p align="center">
  <a href="#requirements"
    ><img
      alt="Platform: macOS 26 or later"
      src="https://img.shields.io/badge/platform-macOS%2026%2B-blue?style=flat-square"
  /></a>
</p>

<h3 align="center"><strong>A live mentor for your Mac.</strong> It watches how you work and shows you a better way when there is one.</h3>

**Status:** early. Athina runs on macOS 26 or later, and feedback is wanted:
[issues](https://github.com/getathina/athina/issues) are welcome. It is
open source under the [Apache License 2.0](LICENSE).

## Overview

Athina sits in your menu bar and notices what you are working on: the app in
front, its window, and the text on your screen, read on your Mac. When it sees
a faster way to do what you are doing, a risk you may have missed, or a step
that will not get you where you are going, it tells you in a small note under
the menu bar and can outline the spot on screen it means. It asks a model
with your own API key for Anthropic, OpenAI or OpenCode, so you pay for what
it asks, under an hourly limit you set (see
[spend control](docs/mentor-loop.md#spend-control)), and nothing else leaves
your Mac (see [Privacy](#privacy)).

## How it works

```
 ON YOUR MAC                          ┆  AT YOUR MODEL PROVIDER, ON YOUR KEY
                                      ┆
   what you are doing: the app in     ┆
   front, its window, the screen text ┆
                   │                  ┆
                   ▼                  ┆
 ┌──────────────────────────────────┐ ┆
 │ sensing                          │ ┆
 │ nothing before Allow, while      │ ┆
 │ paused, or on an excluded app    │ ┆
 └─────────────────┬────────────────┘ ┆
                   ▼                  ┆
 ┌──────────────────────────────────┐ ┆
 │ journal                          │ ┆
 │ what was read, kept on this Mac  │ ┆
 └─────────────────┬────────────────┘ ┆
                   │ you switch apps  ┆
                   │ or stop typing   ┆
                   ▼                  ┆
 ┌──────────────────────────────────┐ ┆  ┌────────────────────────────────┐
 │ triage                           │ ┆  │ the cheap model                │
 │ at most once every 20 s, and     ├─┼──▶ is the latest screen's         │
 │ only when the screen changed     ◀─┼──┤ text worth a look?             │
 └─────────────────┬────────────────┘ ┆  └────────────────────────────────┘
   no: back to     │ yes              ┆
   watching        ▼                  ┆
 ┌──────────────────────────────────┐ ┆  ┌────────────────────────────────┐
 │ mentor                           │ ┆  │ the strong model               │
 │ 2 min since the last mentor      ├─┼──▶ reads the recent screens'      │
 │ call, and under the hourly       │ ┆  │ text, a thumbnail and what     │
 │ spend cap                        ◀─┼──┤ you seem to be after           │
 └─────────────────┬────────────────┘ ┆  └────────────────────────────────┘
   most often      │ a suggestion     ┆
   nothing         ▼                  ┆
 ┌──────────────────────────────────┐ ┆
 │ a note under the menu bar, and   │ ┆
 │ a callout on the spot it means,  │ ┆
 │ when it means one                │ ┆
 └─────────────────┬────────────────┘ ┆
                   ▼                  ┆
   your answer, kept in the journal:  ┆
   Tell Me More, Not Now (that        ┆
   category of note waits an hour)    ┆
   or Never for This (that category   ┆
   stops for this app)                ┆
```

Two models share the work. A quick, inexpensive one takes a look whenever what you are doing changes, and a stronger one looks closer only when the first finds something worth it.
By default they are Claude Haiku 4.5 and Claude Opus 5, on Anthropic and on OpenCode, and GPT-6 Luna and GPT-6 Sol on OpenAI; Settings > Models changes either one, and how much it thinks before answering.

Athina also keeps an **understanding** of what you appear to be working toward, a short note it rewrites as you work, so it can tell you when an approach will not get you where you are going.
It is forgotten after 4 hours without activity and at the start of a new day, and Settings > Models shows it and resets it whenever you like.

Everything Athina asks counts against one **hourly limit**, $1 by default: it asks less often as the hour's spend nears the limit, and stops at it until the next hour.
Change it in [Settings > Models > Spend at most](docs/mentor-loop.md#spend-control).

[Privacy](#privacy) says what is sent and what stays on your Mac.

## Privacy

- Nothing is captured or sent until you choose Allow in the Setup window,
  which opens first, and Settings > Privacy withdraws that at once.
- Everything Athina keeps, which is what it has seen and your settings, stays
  on this Mac, and so does the sound of your voice. Athina sends only to the
  company you choose in Settings > Models, Anthropic, OpenAI or OpenCode, and
  to no one else.
- What it sends is the text on your screen, read on your Mac, with the names
  of the app and window in front and the text of the field you are working
  in; a summary of your recent activity and your answers to its suggestions;
  and its understanding of what you appear to be working toward. A closer look
  also takes the latest screenshot, unless you turn that off in
  Settings > Models; a question you ask about a suggestion is sent as words,
  never as audio; and while Athina mentors only inside your mentorship
  contexts, their names and descriptions go too. File names and keystrokes are
  never sent.
- Apps you exclude (Keychain Access, Passwords and common password managers
  to begin with) and password fields are never read.
- Pause stops Athina watching. What it keeps expires, screenshots after 6
  hours and text after 7 days by default, and Settings > Privacy deletes it
  all at any time.

The [privacy model](docs/privacy.md) has the full account of what is sent, to
whom, and what is kept.

## Requirements

- macOS 26 or later (developed and measured on macOS 27, Apple Silicon)

## Install

1. Download `Athina-<version>.dmg` or `Athina-<version>.zip` from the
   repository's [GitHub Releases](https://github.com/getathina/athina/releases).
2. Open the `.dmg` and drag Athina onto Applications, or unzip the `.zip` into
   Applications.
3. Open Athina. Releases are not notarized yet, so macOS refuses the first
   launch: choose **Done**.
4. In System Settings > Privacy & Security, choose **Open Anyway** next to
   Athina, and confirm.

Each update asks again, and macOS asks once whether the new copy may use your
saved key (see [Unsigned releases](docs/releasing.md#unsigned-releases)).
There are no automatic updates yet: download a new version and drag it over
the old one. Your settings, your saved key and what Athina has kept carry
over, and a copy built from source shares them too (see
[A released copy and your data, grants, and key](docs/releasing.md#a-released-copy-and-your-data-grants-and-key)).
To build Athina from source instead, see [CONTRIBUTING.md](CONTRIBUTING.md).

**Try it without a key.** From a source checkout, `make run` shows Athina at
work with no API key and nothing to pay: it watches your real screen, and its
suggestions come from model answers recorded earlier. It takes Xcode 26 or
later, your Allow in the Setup window and the two permissions below;
[CONTRIBUTING.md](CONTRIBUTING.md) has the setup.

## Setup: an API key

Athina needs an API key for the provider you choose at the top of
Settings > Models: Anthropic, the default; OpenAI; or OpenCode, which serves
both companies' models ([Providers](docs/mentor-loop.md#providers)). Choosing
a provider you have not allowed yet asks for your Allow first, since what is
sent then goes to another company. Open Settings > Models (the menu's Add API
Key item goes there), paste the key, press Save, then Test Connection: it asks
one tiny question and tells you which model answered, or what went wrong. Each
provider's key is kept safely on this Mac and sent only to that provider;
Athina shows only its last four characters, and never reads or changes another
tool's setup, such as Claude Code's, Codex's or OpenCode's. Without a key for
the chosen provider Athina sends nothing, and its menu says so. Remove asks
first, then deletes the saved key.

## Permissions

A first launch opens the Setup window, which asks before anything else whether
Athina may watch the screen and send what it reads to the chosen provider,
Anthropic by default; nothing is captured or sent until you choose
Allow ([Consent](docs/privacy.md#consent)). It then walks on through the two
permissions Athina needs, asking for neither until you press its button, the
model and its key, and what to expect; the other two permissions are optional
and serve only talking back ([how it asks](docs/privacy.md#permissions)).

| Permission | Lets Athina | Without it |
| --- | --- | --- |
| Screen Recording | Take a screenshot of the display you are working on when what you are doing changes, and read its text on this Mac | Athina still reads the app and window in front and the field you are working in, but no screen text and no screenshots |
| Accessibility | Read the title of the window in front and the text of the field you are working in, and outline the spot a suggestion is about | Athina still reads the screen's text and knows which app is in front, but outlines nothing on screen |
| Microphone (optional) | Hear you while you hold the talk-back shortcut | Talking back is off, and pressing the shortcut says so |
| Speech Recognition (optional) | Turn what you say into text on this Mac; the audio never leaves it | Talking back is off, and pressing the shortcut says so |

## Develop

Athina is built with the Swift Package Manager. Plain `make` lists every
command, `make run` shows Athina at work with no key and nothing to pay, and
`make check` is what a change passes before it is pushed.
[CONTRIBUTING.md](CONTRIBUTING.md) covers setup, the daily loop, the rules and
how a change reaches `main`; `docs/` holds the reference:

| Doc | Covers |
| --- | --- |
| [architecture.md](docs/architecture.md) | how the code is laid out and how its parts fit together |
| [mentor-loop.md](docs/mentor-loop.md) | when Athina asks a model and what it shows: suggestions, outlines on screen, keyboard shortcuts, talking back, mentorship contexts, the understanding, spend control |
| [privacy.md](docs/privacy.md) | what leaves the Mac, what is kept, and for how long |
| [debug-panel.md](docs/debug-panel.md) | the window for troubleshooting Athina |
| [design.md](docs/design.md) | the design conventions, the app icon and the menu bar mark |
| [code-style.md](docs/code-style.md) | the Swift style and how it is checked |
| [testing.md](docs/testing.md) | what each kind of test covers and where it runs |
| [replay.md](docs/replay.md) | running Athina on recorded model answers, with no key and nothing to pay |
| [e2e.md](docs/e2e.md) | the end-to-end checks that drive the real app |
| [ci.md](docs/ci.md) | the checks every change passes before it merges |
| [releasing.md](docs/releasing.md) | how a release is made, and why macOS asks before opening one |
