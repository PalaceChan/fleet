# Fleet development Makefile.
#
# Tests run in a DEDICATED disposable Emacs server so they never touch the
# user's editing Emacs (see AGENTS.md).  `make test` starts that server,
# runs ERT through emacsclient, then stops it.

EMACS      ?= emacs
PYTHON     ?= /usr/bin/python3
TEST_SOCK  ?= fleet-test-$(shell id -u)
LISP       := $(wildcard lisp/*.el)
TESTS      := $(wildcard tests/*-tests.el)
ROOT       := $(CURDIR)
# The installed ECA package (and its dependencies) are activated through
# package.el so exactly the user's current versions are used.
LOADPATH   := -L $(ROOT)/lisp -L $(ROOT)/tests \
  --eval '(progn (require (quote package)) (package-initialize))'

.PHONY: help compile clean test test-el test-py test-native server-start server-stop lint

help:
	@echo "targets: compile  test  test-el  test-py  test-native  lint  clean"

compile:
	$(EMACS) -Q --batch $(LOADPATH) \
	  --eval '(setq byte-compile-error-on-warn nil)' \
	  -f batch-byte-compile $(LISP)

clean:
	rm -f lisp/*.elc tests/*.elc
	rm -rf bridge/__pycache__ tests/__pycache__

# --- dedicated test server -------------------------------------------------
server-start:
	@$(EMACS) -Q --daemon=$(TEST_SOCK) $(LOADPATH) \
	  --eval '(setq load-prefer-newer t)' >/dev/null 2>&1 || true
	@sleep 1

server-stop:
	@emacsclient -s $(TEST_SOCK) --eval '(kill-emacs)' >/dev/null 2>&1 || true

# Run ERT in the dedicated server.  Results are printed as a summary line
# plus failures; the server is stopped afterwards.
test-el: server-start
	@emacsclient -s $(TEST_SOCK) --eval \
	  '(progn (setq load-prefer-newer t) (load "$(ROOT)/tests/fleet-test-runner.el" nil t) (fleet-test-run-all "$(ROOT)"))' \
	  | sed -e 's/^"//' -e 's/"$$//' | $(PYTHON) -c 'import sys; print(sys.stdin.read().encode().decode("unicode_escape"))'
	@$(MAKE) --no-print-directory server-stop

test-py:
	$(PYTHON) -m unittest discover -s tests -p 'test_*.py' -v

test: test-py test-el

# Opt-in: exercises the installed native ECA pair and real user systemd.
test-native:
	FLEET_TEST_NATIVE=1 $(MAKE) test-el

lint:
	$(EMACS) -Q --batch $(LOADPATH) \
	  --eval '(require (quote checkdoc))' \
	  --eval '(dolist (f (list $(foreach f,$(LISP),"$(ROOT)/$(f)"))) (checkdoc-file f))'
