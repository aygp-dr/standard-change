#!/bin/sh
# shebang.sh [--selftest] -- every script names its interpreter the one agreed way.
#
# THE QUESTION THIS SETTLES, because it was asked and the obvious answer is
# wrong: should the 42 `#!/bin/sh` scripts become `#!/usr/bin/env sh` "for
# FreeBSD portability"?
#
# No. `/bin/sh` is the one interpreter path POSIX guarantees (XBD 2.9.1.1,
# and `sh` in XCU is specified to be there), and FreeBSD 14.4 ships a real
# binary at it -- not a symlink to something that might be swapped. There is no
# host in the matrix where `/bin/sh` is absent and `env sh` would find one. So
# `env sh` buys nothing and costs two things:
#
#   - `#!/usr/bin/env sh -e` does not work. env-form shebangs get ONE argument
#     on most kernels, so the option is passed as a single word and the exec
#     fails. Direct-path shebangs can carry an option. Nothing here uses that
#     today (every script says `set -eu` on its own line, which is better), but
#     giving up the ability for no gain is not portability.
#   - `env` resolves through PATH. Irrelevant here because nothing in this repo
#     is setuid and PATH is the operator's -- but it is the reason `env` is not
#     a blanket improvement, and it is worth saying rather than implying that
#     `env` is strictly safer.
#
# The rule that IS load-bearing is the other half: a NON-POSIX interpreter has
# no guaranteed path, and hardcoding one is what actually breaks on FreeBSD.
# `bash` is `/usr/local/bin/bash` here and `/bin/bash` on Linux; `/bin/bash`
# does not exist on this host at all. `.github/config/apply.sh` needs bash (it
# uses `set -o pipefail`, `local`, arrays and process substitution -- 9 SC3xxx
# findings under `-s sh`) and correctly says `#!/usr/bin/env bash`.
#
# So, two forms and no others:
#
#   #!/bin/sh                 a POSIX shell script. The guaranteed path.
#   #!/usr/bin/env <interp>   anything else. The path is not guaranteed, so ask.
#
# And one refusal that is neither: a VERSION-PINNED interpreter.
# `#!/usr/bin/env python3.11` works on this host today because python3 IS
# 3.11.15, and stops working the day `pkg upgrade` moves to 3.12 -- a script
# that runs everywhere until it runs nowhere, with no warning in between. Ask
# for `python3` and get whatever python3 is.
#
# Exit 0 clean, 1 findings. Same contract as every other gate
# (docs/exit-codes.org). --selftest proves it can refuse: a rule nobody has
# watched reject something is a hypothesis, not a control.
set -eu
cd "$(dirname "$0")/.."

# classify <first-line> -- print a refusal reason, or nothing when the form is
# one of the two agreed ones. The whole policy is here, in one function, so the
# selftest below exercises the SAME code the scan does. A negative test against
# a reimplementation of the rule proves the reimplementation can fail.
classify() {
  case "$1" in
    '#!/bin/sh')            return 0 ;;
    '#!/usr/bin/env sh')
      echo "use #!/bin/sh -- POSIX guarantees that path; env sh gains nothing and loses shebang options" ;;
    '#!/usr/bin/env '*)
      _interp=${1#'#!/usr/bin/env '}
      case "$_interp" in
        '')          echo "#!/usr/bin/env with no interpreter" ;;
        *' '*)       echo "env-form shebangs get one argument on most kernels; '$_interp' will not exec" ;;
        *.*)         echo "version-pinned interpreter '$_interp' -- ask for the unpinned name; a pin breaks on the next upgrade" ;;
        *)           return 0 ;;
      esac ;;
    '#!'*)
      echo "absolute path to a non-POSIX interpreter (${1#'#!'}) -- only /bin/sh is a guaranteed path; use #!/usr/bin/env" ;;
    *)  echo "no shebang" ;;
  esac
}


# THE EXPECTED REASON, NOT JUST THE EXPECTED REFUSAL.
#
# The first version of this selftest asserted only that each fail/ fixture was
# refused, and a mutation caught it: deleting the absolute-path arm entirely
# still refused `#!/bin/bash`, because it then fell through to the catch-all and
# was reported as "no shebang". Six of six still "passed" while the rule the
# fixture exists to exercise was gone.
#
#   $ sed "s|^    '#!'\*)|    '#!NEVERMATCH'*)|" gates/shebang.sh > mutant
#   $ ./mutant --selftest
#     shebang --selftest: 9/9 fixtures, 0 failure(s)    <-- mutant SURVIVED
#
# That is exactly spec.org defect class 7 -- a check satisfied by something
# other than the thing it is about -- reproduced inside the check written to
# demonstrate the opposite. So each case now declares the SUBSTRING its reason
# must contain, and a refusal for the wrong reason is a failure.
#
# The table is the case list, not the directory: a fixture with no declared
# expectation, and an expectation with no fixture, are both failures. A suite
# that silently runs zero cases reports 0/0 and exits 0, which is the defect
# gates/observation-test.sh:93 still has.
FAIL_CASES="absolute-bash.sh|absolute path to a non-POSIX interpreter
absolute-bash-local.sh|absolute path to a non-POSIX interpreter
env-sh.sh|POSIX guarantees that path
version-pinned.sh|version-pinned interpreter
env-with-option.sh|one argument
no-shebang.sh|no shebang"
PASS_CASES="posix-sh.sh env-bash.sh env-python3.sh"

if [ "${1:-}" = "--selftest" ]; then
  FX=gates/fixtures/shebang
  fails=0; n=0
  # SPLIT ON NEWLINES ONLY. The expected reasons contain spaces, and the
  # default IFS split each one into five "missing fixture" cases that the suite
  # dutifully reported as failures -- 25 cases where there are 9. Caught because
  # the count assertion below disagreed with the table; without it the suite
  # would have been merely noisy instead of wrong.
  _nl='
'
  _oifs=$IFS; IFS=$_nl
  for row in $FAIL_CASES; do
    IFS=$_oifs
    name=${row%%|*}; want=${row#*|}
    n=$((n + 1))
    f="$FX/fail/$name"
    if [ ! -f "$f" ]; then
      printf '  FAIL  %-24s fixture is missing; this case tested nothing\n' "$name"
      fails=$((fails + 1)); continue
    fi
    why=$(classify "$(head -1 "$f")")
    case "$why" in
      '')     printf '  FAIL  %-24s ACCEPTED -- this gate cannot reject it\n' "$name"
              fails=$((fails + 1)) ;;
      *"$want"*)
              printf '  ok    %-24s refused: %s\n' "$name" "$why" ;;
      *)      printf '  FAIL  %-24s refused for the WRONG reason.\n' "$name"
              printf '        wanted a reason containing: %s\n' "$want"
              printf '        got:                        %s\n' "$why"
              fails=$((fails + 1)) ;;
    esac
    IFS=$_nl
  done
  IFS=$_oifs
  for name in $PASS_CASES; do
    n=$((n + 1))
    f="$FX/pass/$name"
    if [ ! -f "$f" ]; then
      printf '  FAIL  %-24s fixture is missing; this case tested nothing\n' "$name"
      fails=$((fails + 1)); continue
    fi
    why=$(classify "$(head -1 "$f")")
    if [ -z "$why" ]; then
      printf '  ok    %-24s accepted\n' "$name"
    else
      printf '  FAIL  %-24s REFUSED a conforming form: %s\n' "$name" "$why"
      fails=$((fails + 1))
    fi
  done
  # A suite that ran no cases has established less than one that ran some.
  if [ "$n" -lt 9 ]; then
    echo "  FAIL  the suite ran $n cases and there are 9; it cannot have checked them"
    exit 1
  fi
  echo "  shebang --selftest: $((n - fails))/$n cases, $fails failure(s)"
  [ "$fails" = 0 ] || exit 1
  exit 0
fi

# THE FILE SET IS DERIVED, NOT LISTED. Every tracked executable, plus every
# tracked .sh and .py whether or not the mode bit is set -- so a new script is
# covered the moment it is added, and a script that lost its +x is still
# checked. `git ls-files` also settles the worktrees question for free: nothing
# under worktrees/ is tracked here, so a sibling checkout is never scanned.
#
# gates/fixtures/ is excluded BY NAME. The fixtures above are deliberately
# malformed; scanning them would make this gate permanently red and the obvious
# repair would be to delete the only evidence that it works.
FILES=$( { git ls-files -s | awk '$1=="100755"{print $4}'
           git ls-files '*.sh' '*.py'; } | sort -u | grep -v '^gates/fixtures/' )

rc=0; n=0; bad=0
for f in $FILES; do
  [ -f "$f" ] || continue
  n=$((n + 1))
  why=$(classify "$(head -1 "$f")")
  [ -n "$why" ] || continue
  printf '  %s:1: %s\n' "$f" "$why"
  bad=$((bad + 1))
  rc=1
done
echo "  shebang: $n scripts, $bad finding(s)"
exit $rc
