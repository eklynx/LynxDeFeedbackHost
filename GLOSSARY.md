# Glossary

**Update channel**
Which stream of builds a user wants to be offered by the updater. One of Release, Pre-release or Nightly. Each channel also offers everything in the channels above it.
_Avoid_: track, ring, stream

**Release**
A build we started, with fully tested features and fixes, ready for everyone. The default channel.

**Pre-release**
A build we started with features and fixes that are developed but not tested enough for a full release.

**Nightly**
An automatic daily build of the latest work, made only when there are new changes since the previous one. Only the last 7 are kept.

**Marketing version**
The plain `X.Y.Z` version people see for a release.

**Full version**
The marketing version, plus for nightlies a build time and short commit hash after a dash. Names builds, downloads and update messages.

**Build number**
A number that always rises from one build to the next, across all channels. Orders builds for the updater; people don't read it.
