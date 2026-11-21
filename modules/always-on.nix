# V2CC always-on settings: no idle system sleep (the display still sleeps),
# start up after a power failure, wake for network access where supported,
# idle auto-logout off, and no unattended installation of macOS updates.
#
# The settings themselves are in always-on.sh, which is included as text so
# that every value is a visible line of the activation script: the
# coexistence guard (lib/system-guard.sh) compares those lines, and
# tests/run.sh runs the same file against stub commands.
#
# nix-darwin's own power options are not used: they call `systemsetup` and
# discard its output, and on macOS 27 `systemsetup` cannot even be read
# without root, so a failure inside it would be invisible in the deploy log.
# `pmset` returns a real exit status and is read back by verify.sh with the
# same key names.
#
# Automatic login is deliberately not here. Its password must never reach
# the Nix store, which is world-readable. See auto-login.sh.
{ lib, ... }:

let
  # Comment and blank lines stay out of the activation script, so rewording
  # a comment is not a change to the machine that the guard has to refuse.
  isCode = line: builtins.match "[[:space:]]*(#.*)?" line == null;
  code = lib.concatStringsSep "\n" (
    lib.filter isCode (lib.splitString "\n" (builtins.readFile ./always-on.sh))
  );
in
{
  system.activationScripts.power.text = lib.mkAfter code;
}
