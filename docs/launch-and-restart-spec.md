# Launch, single-instance and crash-restart specification

Source of truth for code: `DeFeedbackHost/Lifecycle/LaunchSupervision.swift`. Tests: `DeFeedbackHostTests/LifecycleTests.swift`.

## Requirements
1. **Single instance.** However many launch paths fire (login agent, Finder, Dock, second launch), only one copy runs. A later launch activates the running copy and exits 0.
2. **Crash restart.** With *Restart after a crash* on, an abnormal exit is restarted regardless of how the app was launched.
3. **Intentional quit stays quit.** Quit, logout, shutdown and SIGTERM exit 0 and are never restarted.

## Settings (independent)
| Setting | Mechanism |
|---|---|
| Launch at login | `…DeFeedbackHost.login` agent, `RunAtLoad` |
| Restart after a crash | `…DeFeedbackHost.supervisor` agent, `KeepAlive{SuccessfulExit:false}`, started on demand |

## Rules (each is covered by a test)
| Id | Rule | Test |
|---|---|---|
| L1 | No other instance, restart off → run directly | `runsDirectlyWhenRestartIsOff` |
| L2 | Restart on, not launched by the supervisor → ask launchd to start the supervised job, exit 0 without taking the lock | `handsOffWhenNotSupervised` |
| L3 | Already under the supervisor → run | `runsWhenAlreadySupervised` |
| L4 | Lock held, manual launch → activate holder, exit 0, never kill | `secondManualLaunchActivatesHolder` |
| L5 | Hand-off refused → fall through to the lock (run, or activate the holder) | `failedHandOffFallsThroughToTheLock` |
| L6 | Supervisor job identified by `XPC_SERVICE_NAME` | `detectsSupervisorFromEnvironment` |
| L7 | Lock is exclusive, releasable, fails open | `FileInstanceLockTests` |
| L8 | Hung/orphaned holder: supervised launches retry, then SIGKILL after repeated strikes with a stale heartbeat; healthy holders are never killed | `StaleHolderPolicyTests` |

## Manual verification checklist (real launchd; cannot be unit-tested)
Install a Release build anywhere (no `/Applications` requirement). Turn the settings on in Settings › General; approve in System Settings › Login Items if prompted.

1. Login: with *Launch at login* on, log out/in → exactly one DeFeedbackHost process (`pgrep -x DeFeedbackHost | wc -l` → 1).
2. Second launch: open the app again from Finder → existing window comes forward, still one process.
3. Finder + restart on: quit, open from Finder → one process, and `launchctl print gui/$(id -u)/com.eklynx.sound.DeFeedbackHost.supervisor` shows it running.
4. Crash, supervised: `kill -SEGV <pid>` → new pid within ~10 s. Repeat with `kill -9`.
5. Crash after a login launch: same as 4.
6. Quit: Cmd+Q → stays closed (wait 30 s).
7. `kill <pid>` (SIGTERM) → stays closed.
8. Restart/shutdown the Mac → app is not relaunched by the supervisor in a loop; with *Launch at login* on it starts once.
9. Enable *Restart after a crash* while a Finder-launched copy is running → "Relaunch Now" banner appears; pressing it quits and returns under the supervisor.
10. Toggles are independent: restart on + login off → no start at login, crash still restarts.
11. Hung holder: `kill -STOP <pid>` the supervised copy, then `launchctl kickstart -k`-less launches: after ~3 retries the hung copy is killed and a fresh one runs. (`kill -CONT` first if you abort.)

## Tunables (UserDefaults, CLI-settable)
Each is its own key in the `com.eklynx.sound.DeFeedbackHost` domain (unlike the `HostSettings` JSON blob). Applied at next launch; invalid values are clamped. Covered by `LifecycleTuningTests`.

| Key | Type | Default | Range |
|---|---|---|---|
| `Lifecycle.heartbeatInterval` | float, seconds | 2 | 0.5 – 60 |
| `Lifecycle.staleAfter` | float, seconds | 15 | ≥ 3 × heartbeat |
| `Lifecycle.strikesBeforeKill` | int | 3 | 1 – 20 |

```
defaults write com.eklynx.sound.DeFeedbackHost Lifecycle.staleAfter -float 30
defaults read  com.eklynx.sound.DeFeedbackHost Lifecycle.staleAfter
defaults delete com.eklynx.sound.DeFeedbackHost Lifecycle.staleAfter
```
The crash-restart delay (`ThrottleInterval`, 10 s) lives in the supervisor plist, not UserDefaults; changing it needs a rebuild and re-registering the agent.
