# oojq v0.1.1 Makefile
#
# Build, the verification gate, and the three oracles that check the answers:
# test (1036 assertions), parity (byte-compare against the installed jq), and
# sweep (corpus-blind probes that can find what parity cannot).
#
# Usage:
#   make build       - compile main.oo to dist/oojq
#   make check       - run oodac check on every .oo file
#   make line-cap    - enforce 16-256 line cap on every .oo and .oot (shim-exempt)
#   make file-law    - reject forbidden file extensions and stray docs
#   make academy     - verify every .oo has the 4-element Academy header
#   make density     - enforce at most 8 pages per directory
#   make parity      - byte-compare a corpus against the installed jq, in 3 output modes
#   make sweep       - byte-compare corpus-blind probes against jq (discovers, parity confirms)
#   make coverage     - count how many assertions name each dispatched builtin
#   make dead-tests  - fail when two assertions share a name
#   make verify      - run line-cap, file-law, academy, density, and check
#   make clean       - remove build artifacts

OODA_COMPILER ?= $(firstword $(wildcard $(HOME)/.openooda/bin/oodac $(CURDIR)/../../openOODA/oodac/bin/oodac))
OODACODEX ?= $(HOME)/.openooda/northstar.oot
OO_LIST_AMBIENT_QUOTA ?= 8589934592
export OO_LIST_AMBIENT_QUOTA
BIN := dist/oojq

# Every page in the tree rather than a hand written list, which had drifted by
# ten pages, and a page missing from it meant an edit to it did not rebuild.
SRC := $(shell find . -name '*.oo' -not -path './dist/*' -not -path './.ooda-cache/*' | sed 's|^\./||' | sort)

.PHONY: all build check line-cap file-law academy density suggest-audit dead-tests dup-names test parity sweep coverage verify install uninstall package-deb package-rpm package-arch package clean

all: build verify test

build: $(BIN)

$(BIN): $(SRC)
	@mkdir -p dist .ooda-cache/ooda-tmp
	OO_LIST_AMBIENT_QUOTA=$(OO_LIST_AMBIENT_QUOTA) OODACODEX=$(OODACODEX) OODA_COMPILER=$(OODA_COMPILER) OODA_NO_JAIL=1 $(OODA_COMPILER) build main.oo -o $(BIN)
	@chmod +x $(BIN)
	@cp -a $(BIN) dist/oojq-linux-x86_64
	@sha256sum dist/oojq-linux-x86_64 > dist/oojq-linux-x86_64.sha256
	@echo "built $(BIN) (and dist/oojq-linux-x86_64)"

# --- Verification gate ---------------------------------------------------------

# A shim is a file whose every non-comment line is an import. Shims skip the
# 16-line floor. The 320-line ceiling still applies to them without exception.
#
# The ceiling was 256 and was raised for one reason, measured rather than felt:
# openOODA has no function values, so the evaluator's mutual recursion
# (eval_text -> eval_filter -> run_builtin -> eval_text) cannot be split without
# an import cycle, and every feature that reads a sub-filter has to be
# dispatched from filter/run/eval_run.oo. At 256 that page refused features for
# want of one line. It is raised for every page rather than exempted, so the rule
# does not teach that some pages are special. No other page is near either
# number: the next largest are 250, 250 and 248, so nothing but the evaluator
# actually gets longer.
line-cap:
	@violations=0; \
	for f in $$(find . -name "*.oo" -o -name "*.oot"); do \
		n=$$(wc -l < "$$f"); \
		if [ $$n -gt 256 ]; then \
			echo "VIOLATION: $$f = $$n lines (exceeds 256)"; violations=$$((violations+1)); \
			continue; \
		fi; \
		code=$$(grep -vE '^[[:space:]]*(//.*)?$$' "$$f" | grep -cvE '^[[:space:]]*import[[:space:]]+"'); \
		if [ "$$code" = "0" ]; then continue; fi; \
		if [ $$n -lt 16 ]; then \
			echo "VIOLATION: $$f = $$n lines (under 16-line floor, not a shim)"; violations=$$((violations+1)); \
		fi; \
	done; \
	if [ $$violations -gt 0 ]; then echo "FAIL: $$violations files violate the Page Rule"; exit 1; fi; \
	echo "PASS: Page Rule sizing (16-256 lines, shims exempt from floor) holds"

file-law:
	@forbidden="py js ts rb pl json yaml toml"; \
	violations=0; \
	for ext in $$forbidden; do \
		found=$$(find . -name "*.$$ext" -not -path "./.git/*" -not -path "./dist/*" -not -path "./.ooda-cache/*" -not -path "./.blackbox/*" 2>/dev/null | head -3); \
		if [ -n "$$found" ]; then \
			echo "VIOLATION: .$$ext forbidden:"; echo "$$found"; violations=$$((violations+1)); \
		fi; \
	done; \
	for f in $$(find . -name "*.md" -not -path "./.git/*" -not -path "./.ooda-cache/*" -not -path "./.blackbox/*" 2>/dev/null); do \
		if [ "$$f" != "./README.md" ] && [ "$$f" != "./AGENTS.md" ]; then \
			echo "VIOLATION: .md forbidden outside README.md and AGENTS.md: $$f"; violations=$$((violations+1)); \
		fi; \
	done; \
	for f in $$(find . -name "*.sh" -not -path "./.git/*" -not -path "./dist/*" 2>/dev/null); do \
		if [ "$$f" != "./install.sh" ] && [ "$$f" != "./uninstall.sh" ]; then \
			echo "VIOLATION: .sh forbidden outside install.sh and uninstall.sh: $$f"; violations=$$((violations+1)); \
		fi; \
	done; \
	if [ $$violations -gt 0 ]; then echo "FAIL: file-law violations"; exit 1; fi; \
	echo "PASS: file law holds"

# --- Suggestion Audit --------------------------------------------------------
#
# "did you mean" is only useful while the list it draws on is the list the
# evaluator actually dispatches. A name that dispatches but cannot be suggested
# is a typo nobody is helped with; a name that can be suggested but does not
# dispatch sends the caller after a builtin that will fail again. Both directions
# are checked here, and both failed the first time this was written, which is the
# whole reason it is a gate and not a comment.

suggest-audit:
	@disp=$$(mktemp); sugg=$$(mktemp); \
	{ grep -ohE 'if w == "[a-z_@0-9]+"' filter/eval/eval_builtin.oo | sed 's/if w == "//;s/"//'; \
	  grep -ohE 'name == "[a-z_@0-9]+"' filter/eval/eval_builtin.oo | sed 's/name == "//;s/"//'; \
	  grep -ohE 'builtin == "[a-z_@0-9]+"' filter/run/*.oo filter/eval/eval_builtin.oo | sed 's/builtin == "//;s/"//'; \
	  grep -ohE '"(map|select|any|all|group_by|sort_by|unique_by|min_by|max_by|first|last|paths|leaf_paths|recurse|walk|limit)"' filter/run/eval_bykey.oo filter/run/eval_run.oo filter/eval/eval_builtin.oo | tr -d '"'; } | sort -u > $$disp; \
	grep -oE 'list_push\(n, "[^"]+"\)' filter/run/eval_suggest.oo | sed 's/.*"\(.*\)".*/\1/' | sort -u > $$sugg; \
	missing=$$(comm -23 $$disp $$sugg | tr '\n' ' '); \
	bad=0; \
	for nm in $$(cat $$sugg); do \
	  case "$$(echo 'null' | ./$(BIN) "$$nm" 2>&1)" in *"unknown builtin"*) \
	    bad=$$((bad+1)); echo "FAIL: suggestable but not dispatched: $$nm";; esac; \
	done; \
	rm -f $$disp $$sugg; \
	if [ -n "$$missing" ]; then echo "FAIL: dispatched but not suggestable: $$missing"; exit 1; fi; \
	if [ $$bad -gt 0 ]; then exit 1; fi; \
	echo "PASS: the suggestion list and the dispatch list agree"

academy:
	@failures=0; \
	for f in $$(find . -name "*.oo" -not -path "./dist/*"); do \
		header=$$(head -7 "$$f"); \
		missing=""; \
		echo "$$header" | grep -q "^// # "        || missing="$$missing title"; \
		echo "$$header" | grep -q "^// Logline:"  || missing="$$missing logline"; \
		echo "$$header" | grep -q "^// Setup:"    || missing="$$missing setup"; \
		echo "$$header" | grep -q "^// Beats:"    || missing="$$missing beats"; \
		if [ -n "$$missing" ]; then \
			echo "FAIL: $$f missing Academy element(s):$$missing"; failures=$$((failures+1)); \
		fi; \
	done; \
	if [ $$failures -gt 0 ]; then echo "FAIL: $$failures academy header violations"; exit 1; fi; \
	echo "PASS: academy headers hold (all 4 elements present in first 7 lines)"

density:
	@violations=0; \
	for d in $$(find . -type d -not -path "./.git*" -not -path "./dist*" -not -path "./.ooda-cache*"); do \
		n=$$(ls "$$d"/*.oo "$$d"/*.oot 2>/dev/null | grep -v '\*' | wc -l); \
		if [ $$n -gt 8 ]; then \
			echo "VIOLATION: $$d holds $$n pages (exceeds 8)"; violations=$$((violations+1)); \
		fi; \
	done; \
	if [ $$violations -gt 0 ]; then echo "FAIL: $$violations directories exceed the density bound"; exit 1; fi; \
	echo "PASS: directory density (<= 8 pages per directory) holds"

check:
	@for f in $$(find . -name "*.oo" -not -path "./dist/*"); do \
		$(OODA_COMPILER) check "$$f" > /tmp/oojq_check.out 2>&1 || { \
			echo "FAIL: $$f does not check"; cat /tmp/oojq_check.out; exit 1; }; \
	done; \
	rm -f /tmp/oojq_check.out; \
	echo "PASS: oodac check holds on all .oo files"


# --- Duplicate Name Audit -----------------------------------------------------
#
# Two pages answering to one function name is a silent miscompile, not a build
# error. filter/builtin/path/setpath.oo and filter/builtin/object/builtin_object.oo
# each grew a grow, of different shapes and different arities. Nothing complained:
# the build was clean, oodac check was clean, and the crash only appeared once
# written.oo linked both pages together. Every setpath case that never grew an
# intermediate was still byte identical to jq while every one that did died with
# a core dump or an out of bounds read, which is the worst shape a defect can
# take, because the passing cases argue for the code being right.
#
# It stayed invisible because the scan for it was a command somebody remembered
# to type. This gate is that command.
dup-names:
	@dups=$$(grep -rhoE '^(pub )?fn [A-Za-z_0-9]+' --include=*.oo . \
		| sed 's/^pub fn /fn /' | sort | uniq -d); \
	if [ -n "$$dups" ]; then \
		echo "VIOLATION: these function names are declared on more than one page:"; \
		echo "$$dups" | while read -r n; do \
			echo "  $$n"; grep -rn "fn $$n" --include=*.oo . | sed 's/^/    /'; \
		done; \
		echo "FAIL: a shared name is how a call reaches the wrong body"; exit 1; \
	fi; \
	tdups=$$(grep -rhoE '^type [A-Za-z_0-9]+' --include=*.oo . | sort | uniq -d); \
	if [ -n "$$tdups" ]; then \
		echo "VIOLATION: these type names are declared on more than one page:"; \
		echo "$$tdups" | sed 's/^/  /'; exit 1; \
	fi; \
	echo "PASS: no function or type name is declared twice"


# --- Dead Test Audit ----------------------------------------------------------
#
# A test suite with no way to notice its own duplicates accumulates them, and
# there is no other mechanism here for retiring a test that no longer protects
# anything. When this gate was first written it found three shared names, and
# every one of them was a continuation of the sentence before it: "and not above
# it", "and the same the other way round". A name that reads as a continuation is
# a name that cannot say which assertion failed, and two assertions sharing one
# are two tests that can be deleted down to one without the suite noticing.
dead-tests:
	@names=$$(mktemp); \
	grep '^[[:space:]]*assert_[a-z]* ".*" ' $(MAKEFILE_LIST) \
	  | sed 's/.*"\([^"]*\)"; *\\$$/\1/' | sort > $$names; \
	n=$$(wc -l < $$names); dup=$$(uniq -d $$names); \
	rm -f $$names; \
	if [ -n "$$dup" ]; then \
	  echo "VIOLATION: assertion names are shared, so a failure cannot say which broke:"; \
	  echo "$$dup"; exit 1; \
	fi; \
	echo "PASS: all $$n assertions carry a name of their own"

# --- Behaviour tests ---------------------------------------------------------
#
# No .json fixture ships in this tree: file-law forbids the extension. Input is
# piped through stdin instead, which also keeps every test on the same code path
# a user would take. The block after the escaping tests pins the engine the
# filter rewrite introduced. Each of those cases was a wrong answer rather than a
# refusal, which is why each is named after the behaviour and not the filter.

DOC = {"name":"oojq","tags":["json","cli"],"meta":{"stars":42,"active":true,"ratio":-3},"note":null}
TMPDOC = /tmp/oojq_test_doc.json
DUPDOC = /tmp/oojq_dup_doc.json
CNT = /tmp/oojq_suite_counts.txt

# The suite helpers, kept in one place because the suite below is split across
# several shell invocations: one command longer than 128 KiB is refused by
# execve, and this suite has already outgrown that. Every chunk starts from
# these definitions and counts into $(CNT); the summary at the end sums the
# chunks, so a broken run still reports every failure it found, not only the
# first chunk that happened to have one.
define SUITE_FNS
pass=0; fail=0; printf '$(DOC)' > $(TMPDOC); assert_out() {   got=$$1; want=$$2; name=$$3;   if [ "$$got" = "$$want" ]; then echo "PASS: $$name"; pass=$$((pass+1));   else echo "FAIL: $$name"; echo "      want [$$want]"; echo "      got  [$$got]"; fail=$$((fail+1)); fi; }; assert_code() {   got=$$1; want=$$2; name=$$3;   if [ "$$got" = "$$want" ]; then echo "PASS: $$name"; pass=$$((pass+1));   else echo "FAIL: $$name (exit $$got, want $$want)"; fail=$$((fail+1)); fi; }; assert_has() {   got=$$1; needle=$$2; name=$$3;   case "$$got" in *"$$needle"*) echo "PASS: $$name"; pass=$$((pass+1));;     *) echo "FAIL: $$name"; echo "      want to contain [$$needle]"; echo "      got [$$got]"; fail=$$((fail+1));; esac; }; assert_bytes() {   got=$$1; want=$$2; name=$$3;   if [ "$$got" = "$$want" ]; then echo "PASS: $$name"; pass=$$((pass+1));   else echo "FAIL: $$name"; echo "      want $$want bytes on stdout"; echo "      got  $$got bytes"; fail=$$((fail+1)); fi; }; mcp() { printf '%s\n' "$$1" | ./$(BIN) --mcp 2>&1; }; run() { echo '$(DOC)' | ./$(BIN) "$$@" 2>&1; }; j() { echo '$(DOC)' | ./$(BIN) "$$@" 2>&1 | tr '\n' '|'; }; jc() { echo '$(DOC)' | ./$(BIN) -c "$$@" 2>&1 | tr '\n' '|'; }; t() { ./$(BIN) -c "$$1" $(TMPDOC) 2>&1 | tr '\n' '@'; }; d() { printf '%s' "$$1" > $(DUPDOC); ./$(BIN) -c "$$2" $(DUPDOC) 2>&1 | tr '\n' '@'; };
endef

test: build
	@rm -f $(CNT);
	@$(SUITE_FNS) \
	assert_out "$$(j '.name')" '"oojq"|' "select a scalar field"; \
	assert_out "$$(j '.meta.stars')" '42|' "select a nested field"; \
	assert_out "$$(j '.meta.ratio')" '-3|' "keep a negative integer signed"; \
	assert_out "$$(j '.note')" 'null|' "render a null literal"; \
	assert_out "$$(j '.meta.active')" 'true|' "render a true literal"; \
	assert_out "$$(j '.tags[]')" '"json"|"cli"|' "iterate an array"; \
	assert_out "$$(j '.meta[]')" '42|true|-3|' "iterate an object into values"; \
	assert_out "$$(echo '[[1],[2]]' | ./$(BIN) -c '[recurse(.[]?)]' 2>&1)" '[[[1],[2]],[1],1,[2],2]' "recurse(f) answers preorder, where a queue would answer [2] before 1"; \
	assert_out "$$(echo '{"a":{"b":1}}' | ./$(BIN) -c '[recurse(.[]?)]' 2>&1)" '[{"a":{"b":1}},{"b":1},1]' "recurse(f) walks into an object"; \
	assert_out "$$(echo '1' | ./$(BIN) -c '[recurse(empty)]' 2>&1)" '[1]' "a recurse(f) whose f answers nothing stops at the value in hand"; \
	assert_out "$$(echo '[[1,2]]' | ./$(BIN) -c '[recurse]' 2>&1)" '[[[1,2]],[1,2],1,2]' "bare recurse is still the object descent"; \
	assert_out "$$(echo '1' | ./$(BIN) -c '[recurse(.*2; . < 20)]' 2>&1)" '[1,2,4,8,16]' "recurse(f; c) is recurse(f | select(c))"; \
	assert_out "$$(echo null | ./$(BIN) -c '1,2 | [recurse(.+1; . < 3)]' 2>&1 | tr '\n' '|')" '[1,2]|[2]|' "recurse is read per value, so a stream is split first"; \
	assert_has "$$(echo '[[1,2]]' | ./$(BIN) -c '[recurse(.[])]' 2>&1)" 'Cannot iterate over' "recurse(f) lets an error through, as in jq"; \
	assert_out "$$(echo '[1,[2,[3]]]' | ./$(BIN) -c '[walk(if type=="number" then .*10 else . end)]' 2>&1)" '[[10,[20,[30]]]]' "walk(f) reaches every depth, not the first"; \
	assert_out "$$(echo '{"a":{"b":[1]}}' | ./$(BIN) -c '[walk(if type=="number" then .+1 else . end)]' 2>&1)" '[{"a":{"b":[2]}}]' "and through nested objects"; \
	assert_out "$$(echo '[[1]]' | ./$(BIN) -c '[walk(if .==[1] then "saw" else . end)]' 2>&1)" '[["saw"]]' "the body is applied to the REBUILT value, so it can match it"; \
	assert_out "$$(echo '{"a":1,"b":2}' | ./$(BIN) -c '[walk(if .==1 then empty else . end)]' 2>&1)" '[{"b":2}]' "a child that answers nothing takes its key with it"; \
	assert_out "$$(echo '[1,2]' | ./$(BIN) -c '[walk(if .==1 then empty else . end)]' 2>&1)" '[[2]]' "and an array child that answers nothing leaves the array shorter"; \
	assert_out "$$(echo '1' | ./$(BIN) -c '[walk(if .==1 then 7,8 else . end)]' 2>&1)" '[7,8]' "walk(f) keeps every answer of its body, where a routed call keeps the last"; \
	assert_out "$$(echo '[1,2]' | ./$(BIN) -c '[walk(empty)]' 2>&1)" '[]' "a walk whose body answers nothing is no answer"; \
	assert_out "$$(echo null | ./$(BIN) -c '1,2 | [walk(.)]' 2>&1 | tr '\n' '|')" '[1]|[2]|' "walk is read per value, so a stream is split first"; \
	assert_out "$$(echo '[{"key":"a"}]' | ./$(BIN) -c from_entries 2>&1)" '{"a":null}' "from_entries reads a missing value as null, which is what walk(f) leans on"; \
	assert_out "$$(echo '[{"Key":"a","Value":1}]' | ./$(BIN) -c from_entries 2>&1)" '{"a":1}' "from_entries reads the Key and Value spellings too"; \
	assert_out "$$(echo '[{"name":"n","Name":"N","value":1}]' | ./$(BIN) -c from_entries 2>&1)" '{"n":1}' "where name beats Name"; \
	assert_out "$$(echo '[{"key":"k","Key":"K","value":1}]' | ./$(BIN) -c from_entries 2>&1)" '{"k":1}' "and key beats Key"; \
	assert_has "$$(echo '[{"k":"a","v":1}]' | ./$(BIN) -c from_entries 2>&1)" 'Cannot use null (null) as object key' "from_entries does not read k or v at all, so it is a key that is not there"; \
	assert_has "$$(echo '[{"key":1,"value":2}]' | ./$(BIN) -c from_entries 2>&1)" 'Cannot use number (1) as object key' "a key that is not a string is refused, naming the kind and the value"; \
	assert_has "$$(echo '[1,2]' | ./$(BIN) -c from_entries 2>&1)" 'Cannot index number with string "key"' "a non-object entry is refused the way jq indexes it"; \
	assert_out "$$(echo '[1,2]' | ./$(BIN) -c 'map_values(.+1)' 2>&1)" '[2,3]' "map_values(f) updates every member of an array"; \
	assert_out "$$(echo '{"a":1,"b":2}' | ./$(BIN) -c 'map_values(.+1)' 2>&1)" '{"a":2,"b":3}' "and every value of an object, keeping the shape"; \
	assert_out "$$(echo '[1,2]' | ./$(BIN) -c 'map_values(1,2)' 2>&1)" '[1,1]' "map_values keeps the FIRST answer per member, where map gathers them all"; \
	assert_out "$$(echo '[1,2]' | ./$(BIN) -c 'map(1,2)' 2>&1)" '[1,2,1,2]' "so map_values is not map, and map is still the one that gathers"; \
	assert_out "$$(echo '{"a":1,"b":2}' | ./$(BIN) -c 'map_values(1,2)' 2>&1)" '{"a":1,"b":1}' "and the first answer rule holds for object values too"; \
	assert_out "$$(echo '[1,2]' | ./$(BIN) -c 'map_values(if .==1 then empty else .*10 end)' 2>&1)" '[20]' "a member that answers nothing is dropped from an array"; \
	assert_out "$$(echo '{"a":1,"b":2}' | ./$(BIN) -c 'map_values(if .==1 then empty else . end)' 2>&1)" '{"b":2}' "and takes its key with it in an object"; \
	assert_out "$$(echo '{"a":1}' | ./$(BIN) -c 'map_values(empty)' 2>&1)" '{}' "a map_values whose body always empties is an empty shape, not empty"; \
	assert_out "$$(echo '{"a":[1,2]}' | ./$(BIN) -c 'map_values(map_values(.+1))' 2>&1)" '{"a":[2,3]}' "map_values nests, since its body is an ordinary filter"; \
	assert_out "$$(echo '[[1],[2]]' | ./$(BIN) -c 'map_values(.[])' 2>&1)" '[1,2]' "and a body that gathers flattens the member it was given"; \
	assert_has "$$(echo '[1,2]' | ./$(BIN) -c 'map_values' 2>&1)" 'map_values' "a bare map_values is refused rather than run over nothing"; \
	assert_out "$$(echo 2 | ./$(BIN) -c 'if . == 1 then "a" elif . == 2 then "b" else "c" end' 2>&1)" '"b"' "elif takes the branch it names"; \
	assert_out "$$(echo 9 | ./$(BIN) -c 'if . == 1 then "a" elif . == 2 then "b" else "c" end' 2>&1)" '"c"' "and falls through to else when no elif matched"; \
	assert_out "$$(echo 1 | ./$(BIN) -c 'if . == 1 then "a" elif . == 2 then "b" end' 2>&1)" '"a"' "elif with no else is still an if that may answer nothing"; \
	assert_out "$$(echo 1 | ./$(BIN) -c 'if . == 1 then 2 elif 3 then 4 elif . == 1 then 5 end' 2>&1)" '2' "a chain of elif is read left to right"; \
	assert_out "$$(echo 1 | ./$(BIN) -c 'if . == 1 then 2 elif 3 then 4 elif . == 1 then 5 else 6 end' 2>&1)" '2' "and a chain may end in an else"; \
	assert_out "$$(echo '"end"' | ./$(BIN) -c 'if . == "if" then 1 elif . == "end" then 2 else 3 end' 2>&1)" '2' "a keyword written inside a string is not a keyword"; \
	assert_out "$$(echo 5 | ./$(BIN) -c 'if . == 1 then "elif" elif . == 2 then "elif elif" else "x" end' 2>&1)" '"x"' "and an elif inside a string does not open a branch"; \
	assert_out "$$(echo 2 | ./$(BIN) -c 'if . == 1 then 10 elif . == 2 then (if . == 2 then 20 else 21 end) else 30 end' 2>&1)" '20' "an elif branch may hold a whole nested if"; \
	assert_out "$$(echo 3 | ./$(BIN) -c 'if . == 1 then 10 elif . == 2 then (if . == 2 then 20 else 21 end) else 30 end' 2>&1)" '30' "and the nested if does not swallow the outer else"; \
	assert_out "$$(echo '[1,2,3]' | ./$(BIN) -c '[.[] | if . == 1 then 1 elif . == 2 then 2 else 3 end]' 2>&1)" '[1,2,3]' "elif works inside a collect, over a stream"; \
	assert_out "$$(echo 2 | ./$(BIN) -c 'if . == 1 then 0 elif . == 2 then (1,2) else 3 end' 2>&1 | tr '\n' '|')" '1|2|' "an elif branch keeps every answer it gives"; \
	assert_out "$$(printf 'null' | ./$(BIN) -c '[1,2,3] | contains([1,2])' 2>&1)" 'true' "contains over two arrays is a subset test, not an equality"; \
	assert_out "$$(printf 'null' | ./$(BIN) -c '[1,2,3] | contains([1,5])' 2>&1)" 'false' "and one member it does not have makes it false"; \
	assert_out "$$(printf 'null' | ./$(BIN) -c '[1,2,3] | contains([])' 2>&1)" 'true' "every array contains the empty array"; \
	assert_out "$$(printf 'null' | ./$(BIN) -c '[1,2] | contains([1,1])' 2>&1)" 'true' "a subset test, so a repeated member is not asked for twice"; \
	assert_out "$$(printf 'null' | ./$(BIN) -c '[[1,2]] | contains([[1]])' 2>&1)" 'true' "and the test recurses, so [[1,2]] contains [[1]]"; \
	assert_out "$$(printf 'null' | ./$(BIN) -c '{"a":1,"b":2} | contains({"a":1})' 2>&1)" 'true' "contains over two objects is a subset over the members asked for"; \
	assert_out "$$(printf 'null' | ./$(BIN) -c '{"a":{"b":1}} | contains({"a":{}})' 2>&1)" 'true' "and it recurses into a member, so an object contains {}"; \
	assert_out "$$(printf 'null' | ./$(BIN) -c '{"a":1} | contains({"a":"1"})' 2>&1)" 'false' "a member of the wrong kind is false, not a refusal"; \
	assert_out "$$(printf 'null' | ./$(BIN) -c '1 | contains(1.0)' 2>&1)" 'true' "numbers pair with numbers, so 1 contains 1.0"; \
	assert_out "$$(printf 'null' | ./$(BIN) -c '"foobar" | contains("oba")' 2>&1)" 'true' "two strings are a substring test"; \
	assert_has "$$(printf 'null' | ./$(BIN) -c '{"a":1} | contains("a")' 2>&1)" 'cannot have their containment checked' "a pair of kinds that cannot be checked is refused, not answered false"; \
	assert_has "$$(printf 'null' | ./$(BIN) -c '["a"] | contains("a")' 2>&1)" 'cannot have their containment checked' "and an array against a string is refused the same way"; \
	assert_has "$$(printf 'null' | ./$(BIN) -c '1 | contains(true)' 2>&1)" 'cannot have their containment checked' "while a number and a boolean do not pair at all"; \
	assert_out "$$(printf 'null' | ./$(BIN) -c '["a","b","a"] | index("a")' 2>&1)" '0' "index over an array is the first member equal to the needle"; \
	assert_out "$$(printf 'null' | ./$(BIN) -c '["a","b","a"] | rindex("a")' 2>&1)" '2' "and rindex is the last one"; \
	assert_out "$$(printf 'null' | ./$(BIN) -c '[1,2,3] | index(2)' 2>&1)" '1' "an array member is found by value, not as text"; \
	assert_out "$$(printf 'null' | ./$(BIN) -c '[1] | index(1.0)' 2>&1)" '0' "so a number member and a decimal needle are the same number"; \
	assert_out "$$(printf 'null' | ./$(BIN) -c '[{"a":1}] | index({"a":1})' 2>&1)" '0' "and an object member is compared whole"; \
	assert_out "$$(printf 'null' | ./$(BIN) -c '[[1]] | index([1])' 2>&1)" 'null' "but an array member never matches, which is the one rule here"; \
	assert_out "$$(printf 'null' | ./$(BIN) -c '["a","b"] | index("z")' 2>&1)" 'null' "a needle that is not there is null, over an array as over a string"; \
	assert_out "$$(printf 'null' | ./$(BIN) -c '[] | index("a")' 2>&1)" 'null' "and an empty array has no index for anything"; \
	assert_out "$$(printf 'null' | ./$(BIN) -c 'null | index(1)' 2>&1)" 'null' "null answers null rather than refusing, as indexing null does"; \
	assert_has "$$(printf 'null' | ./$(BIN) -c '1 | index(1)' 2>&1)" 'Cannot index number with number' "a number is not a searchable shape, so it reads as an index into it"; \
	assert_has "$$(printf 'null' | ./$(BIN) -c '{"a":1} | index("a")' 2>&1)" 'over an object is not supported' "an object is refused rather than guessed at"; \
	assert_has "$$(printf 'null' | ./$(BIN) -c '[1,2] | index(1,2)' 2>&1)" 'takes one value' "an argument written as a generator is refused, not read as its last value"; \
	assert_has "$$(printf 'null' | ./$(BIN) -c '[1,2] | contains(1,2)' 2>&1)" 'takes one value' "and the same refusal holds for contains"; \
	assert_out "$$(printf 'null' | ./$(BIN) -c '["a","b"] | setpath([0]; 1, 2)' 2>&1 | tr '\n' '|')" '[1,"b"]|[2,"b"]|' "setpath still takes a generator on purpose, and answers once per value"; \
	assert_out "$$(j '.name, .meta.stars')" '"oojq"|42|' "comma unions in order"; \
	assert_out "$$(j '.tags[] | .')" '"json"|"cli"|' "pipe feeds iteration onward"; \
	assert_out "$$(echo '{"k":{}}' | ./$(BIN) .k 2>&1)" '{}' "empty object renders as {}"; \
	assert_out "$$(echo '{"f":1.5}' | ./$(BIN) .f 2>&1)" '1.5' "float renders its literal"; \
	assert_out "$$(echo '{"a":[1,2.5,-3]}' | ./$(BIN) -c .a 2>&1)" '[1,2.5,-3]' "floats and ints mix in one array"; \
	assert_out "$$(echo '{"a":1e5}' | ./$(BIN) .a 2>&1)" '1e5' "exponent literal round-trips"; \
	assert_out "$$(echo '{"a":-0.25}' | ./$(BIN) .a 2>&1)" '-0.25' "negative float round-trips"; \
	assert_out "$$(echo '{"a":0.0}' | ./$(BIN) .a 2>&1)" '0.0' "zero float round-trips"; \
	assert_out "$$(echo '{"k":"1.5 is text"}' | ./$(BIN) .k 2>&1)" '"1.5 is text"' "a float inside a string is untouched"; \
	assert_out "$$(echo '{"a":1.5}' | ./$(BIN) -c . 2>&1)" '{"a":1.5}' "a float inside a document"; \
	assert_out "$$(echo '{"a": 1.5}' | ./$(BIN) . 2>&1 | tr '\n' '~')" '{~  "a": 1.5~}~' "default output is jq pretty form"; \
	assert_out "$$(echo '{"a":{"b":[{"c":2.5}]}}' | ./$(BIN) .a.b[0].c 2>&1)" '2.5' "float nested three deep"; \
	assert_out "$$(echo '{"k":[]}' | ./$(BIN) .k 2>&1)" '[]' "empty array renders as []"; \
	assert_out "$$(./$(BIN) .name $(TMPDOC) 2>&1 | tr '\n' '|')" '"oojq"|' "unquoted filter reads a file"; \
	assert_out "$$(./$(BIN) .name, .meta.stars $(TMPDOC) 2>&1 | tr '\n' '|')" '"oojq"|42|' "unquoted comma filter needs no quoting"; \
	assert_out "$$(./$(BIN) .tags[] , .name $(TMPDOC) 2>&1 | tr '\n' '|')" '"json"|"cli"|"oojq"|' "unquoted iterate union"; \
	assert_code "$$(./$(BIN) .name $(TMPDOC) $(TMPDOC) >/dev/null 2>&1; echo $$?)" 2 "a second input file is refused"; \
	assert_out "$$(run '.nope' 2>&1)" 'null' "a missing field is null, as in jq"; \
	assert_code "$$(run '.nope' >/dev/null 2>&1; echo $$?)" 0 "a missing field is exit 0"; \
	assert_code "$$(run '.name|tonumber' >/dev/null 2>&1; echo $$?)" 2 "indexing a string with tonumber is refused"; \
	assert_code "$$(run '.tags[0]' >/dev/null 2>&1; echo $$?)" 0 "indexing an array succeeds"; \
	assert_out "$$(run '.tags[0]' 2>&1)" '"json"' "index the first element"; \
	assert_out "$$(run '.tags[-1]' 2>&1)" '"cli"' "negative index counts from the end"; \
	assert_out "$$(run -c '.tags[0:1]' 2>&1 | tr '\n' '|')" '["json"]|' "a slice is an array"; \
	assert_code "$$(run '.meta.stars[0]' >/dev/null 2>&1; echo $$?)" 2 "indexing a scalar is refused"; \
	assert_out "$$(echo '{"t":["a"]}' | ./$(BIN) .t[9] 2>&1)" 'null' "an out of range index is null"; \
	assert_out "$$(echo '{"t":["a","b"]}' | ./$(BIN) -c '.t[:1]' 2>&1)" '["a"]' "an open slice start"; \
	assert_out "$$(echo '{"t":["a","b"]}' | ./$(BIN) -c '.t[1:]' 2>&1)" '["b"]' "an open slice end"; \
	assert_code "$$(echo '$(DOC)' | ./$(BIN) -c .name >/dev/null 2>&1; echo $$?)" 0 "compact flag precedes the filter"; \
	assert_code "$$(echo '$(DOC)' | ./$(BIN) .name -c >/dev/null 2>&1; echo $$?)" 0 "compact flag also follows the filter"; \
	assert_out "$$(echo '{"t":["a","b"]}' | ./$(BIN) '.t|length' 2>&1)" '2' "length of an array"; \
	assert_out "$$(echo '{"a":1,"b":2}' | ./$(BIN) length 2>&1)" '2' "length of an object"; \
	assert_out "$$(echo '{"s":"abcd"}' | ./$(BIN) '.s|length' 2>&1)" '4' "length of a string"; \
	assert_out "$$(echo '{"n":5}' | ./$(BIN) '.n|length' 2>&1)" '5' "length of a number is the number, as jq has it"; \
	assert_out "$$(echo '{"n":-7}' | ./$(BIN) '.n|length' 2>&1)" '7' "length of a negative number is its magnitude"; \
	assert_out "$$(echo '{"n":-2.5}' | ./$(BIN) -c '.n|length' 2>&1)" '2.5' "length of a negative float drops the sign"; \
	assert_out "$$(echo '{"n":3.5}' | ./$(BIN) -c '.n|length' 2>&1)" '3.5' "length of a positive float is itself"; \
	assert_out "$$(echo '{"n":0}' | ./$(BIN) '.n|length' 2>&1)" '0' "length of zero is zero"; \
	assert_out "$$(echo '{"k":null}' | ./$(BIN) '.k|length' 2>&1)" '0' "length of null is zero"; \
	assert_out "$$(echo '{"k":true}' | ./$(BIN) '.k|length' 2>&1 | grep -c 'has no length')" '1' "length of a boolean is refused by name"; \
	assert_out "$$(echo '{"b":1,"a":2}' | ./$(BIN) -c keys 2>&1)" '["a","b"]' "keys are sorted"; \
	assert_out "$$(echo '{"t":["x"]}' | ./$(BIN) -c keys 2>&1)" '["t"]' "keys of an object"; \
	assert_out "$$(echo '{"n":1}' | ./$(BIN) '.n|type' 2>&1)" '"number"' "an int reports as number"; \
	assert_out "$$(echo '{"n":1.5}' | ./$(BIN) '.n|type' 2>&1)" '"number"' "a float reports as number"; \
	assert_out "$$(echo '{"t":["b","a"]}' | ./$(BIN) -c '.t|sort' 2>&1)" '["a","b"]' "sort orders strings"; \
	assert_out "$$(echo '{"t":["b","a","a"]}' | ./$(BIN) -c '.t|unique' 2>&1)" '["a","b"]' "unique sorts and dedupes"; \
	assert_out "$$(echo '{"t":["a","b"]}' | ./$(BIN) -c '.t|reverse' 2>&1)" '["b","a"]' "reverse flips order"; \
	assert_out "$$(echo '{"t":[1,2,3]}' | ./$(BIN) '.t|add' 2>&1)" '6' "add sums integers"; \
	assert_out "$$(echo '{"t":[]}' | ./$(BIN) '.t|add' 2>&1)" 'null' "add of empty is null"; \
	assert_out "$$(echo '{"t":["a","b"]}' | ./$(BIN) '.t|first' 2>&1)" '"a"' "first element"; \
	assert_out "$$(echo '{"t":["a","b"]}' | ./$(BIN) '.t|last' 2>&1)" '"b"' "last element"; \
	assert_code "$$(echo '{"t":[]}' | ./$(BIN) '.t|first' >/dev/null 2>&1; echo $$?)" 0 "first of empty is null"; \
	assert_code "$$(echo '{"t":["a"]}' | ./$(BIN) '.t|nosuch' >/dev/null 2>&1; echo $$?)" 2 "an unknown builtin is refused"; \
	assert_code "$$(echo '{"n":1}' | ./$(BIN) '.n|reverse' >/dev/null 2>&1; echo $$?)" 2 "reverse refuses a scalar"; \
	assert_out "$$(echo '{"a":1,"b":2}' | ./$(BIN) 'has("a")' 2>&1)" 'true' "has finds a member"; \
	assert_out "$$(echo '{"a":1}' | ./$(BIN) 'has("z")' 2>&1)" 'false' "has reports a missing member"; \
	assert_has "$$(echo '{"a":1}' | ./$(BIN) 'has(1)' 2>&1)" 'Cannot check whether object has a number key' "has on an object refuses a number key as jq does"; \
	assert_out "$$(echo '{"t":[1,2,3]}' | ./$(BIN) '.t|has(0)' 2>&1)" 'true' "has asks an array whether it carries a position"; \
	assert_out "$$(echo '{"t":[1,2,3]}' | ./$(BIN) '.t|has(2)' 2>&1)" 'true' "has on an array is true at the last position"; \
	assert_out "$$(echo '{"t":[1,2,3]}' | ./$(BIN) '.t|has(3)' 2>&1)" 'false' "has on an array is false one past the end"; \
	assert_out "$$(echo '{"t":[1,2,3]}' | ./$(BIN) '.t|has(-1)' 2>&1)" 'false' "has on an array is false before the start"; \
	assert_out "$$(echo '{"t":[1,2,3]}' | ./$(BIN) '.t|has(0.5)' 2>&1)" 'true' "has on an array truncates a fraction toward zero"; \
	assert_out "$$(echo '{"t":[1,2,3]}' | ./$(BIN) '.t|has(2.5)' 2>&1)" 'true' "has on an array truncates 2.5 to the last position"; \
	assert_out "$$(echo '{"t":[]}' | ./$(BIN) '.t|has(0)' 2>&1)" 'false' "has on an empty array is false"; \
	assert_out "$$(echo '{"t":null}' | ./$(BIN) '.t|has(0)' 2>&1)" 'false' "has on a null is false for a number key"; \
	assert_out "$$(echo '{"t":null}' | ./$(BIN) '.t|has("a")' 2>&1)" 'false' "has on a null is false for a string key"; \
	assert_has "$$(echo '{"t":[1,2]}' | ./$(BIN) '.t|has("a")' 2>&1)" 'Cannot check whether array has a string key' "has on an array refuses a string key as jq does"; \
	assert_has "$$(echo '{"t":1}' | ./$(BIN) '.t|has("a")' 2>&1)" 'Cannot check whether number has a string key' "has on a number refuses a string key as jq does"; \
	assert_out "$$(echo '{"s":"Hello"}' | ./$(BIN) '.s|startswith("He")' 2>&1)" 'true' "startswith"; \
	assert_out "$$(echo '{"s":"Hello"}' | ./$(BIN) '.s|endswith("lo")' 2>&1)" 'true' "endswith"; \
	assert_out "$$(echo '{"s":"Hello"}' | ./$(BIN) '.s|endswith("xx")' 2>&1)" 'false' "endswith rejects a short suffix"; \
	assert_out "$$(echo '{"s":"abc"}' | ./$(BIN) '.s|contains("b")' 2>&1)" 'true' "contains finds a substring"; \
	assert_out "$$(echo '{"s":"abc"}' | ./$(BIN) '.s|contains("z")' 2>&1)" 'false' "contains rejects an absent substring"; \
	assert_out "$$(echo '{"s":"HeLLo"}' | ./$(BIN) '.s|ascii_downcase' 2>&1)" '"hello"' "ascii_downcase"; \
	assert_out "$$(echo '{"s":"HeLLo"}' | ./$(BIN) '.s|ascii_upcase' 2>&1)" '"HELLO"' "ascii_upcase"; \
	assert_out "$$(echo '{"s":"ab"}' | ./$(BIN) '.s|ascii_downcase' 2>&1)" '"ab"' "downcase leaves other characters"; \
	assert_out "$$(echo '{"s":"xay"}' | ./$(BIN) '.s|ltrimstr("xa")' 2>&1)" '"y"' "ltrimstr strips a prefix"; \
	assert_out "$$(echo '{"s":"xay"}' | ./$(BIN) '.s|ltrimstr("zz")' 2>&1)" '"xay"' "ltrimstr keeps a non matching prefix"; \
	assert_out "$$(echo '{"s":"aXbXc"}' | ./$(BIN) '.s|test("Xb")' 2>&1)" 'true' "test uses the std regex engine"; \
	assert_out "$$(echo '{"s":"abc"}' | ./$(BIN) '.s|test("zz")' 2>&1)" 'false' "test rejects a non match"; \
	assert_out "$$(echo '{"n":7}' | ./$(BIN) '.n|tonumber' 2>&1)" '7' "tonumber passes a number through"; \
	assert_out "$$(echo '{"s":"12"}' | ./$(BIN) '.s|tonumber' 2>&1)" '12' "tonumber parses digits"; \
	assert_code "$$(echo '{"s":"ab"}' | ./$(BIN) '.s|tonumber' >/dev/null 2>&1; echo $$?)" 2 "tonumber refuses non digits"; \
	assert_out "$$(echo '{"n":7}' | ./$(BIN) '.n|tostring' 2>&1)" '"7"' "tostring renders a number"; \
	assert_out "$$(echo '{"n":[1,5,3]}' | ./$(BIN) '.n|max' 2>&1)" '5' "max finds the largest"; \
	assert_out "$$(echo '{"n":[1,5,3]}' | ./$(BIN) '.n|min' 2>&1)" '1' "min finds the smallest"; \
	assert_out "$$(echo '{"n":[]}' | ./$(BIN) '.n|max' 2>&1)" 'null' "max of empty is null"; \
	assert_out "$$(echo '{"a":1,"b":2}' | ./$(BIN) -c to_entries 2>&1)" '[{"key":"a","value":1},{"key":"b","value":2}]' "to_entries"; \
	assert_out "$$(echo '[{"key":"a","value":1}]' | ./$(BIN) -c from_entries 2>&1)" '{"a":1}' "from_entries"; \
	assert_out "$$(echo '{}' | ./$(BIN) 'range(3)' 2>&1 | tr '\n' '|')" '0|1|2|' "range streams its values"; \
	assert_out "$$(echo '{"t":["a"]}' | ./$(BIN) '.t|join("-")' 2>&1)" '"a"' "join with a separator"; \
	assert_out "$$(echo '{"t":[1]}' | ./$(BIN) '.t|join("-")' 2>&1)" '"1"' "join spells a number member"; \
	assert_out "$$(echo '{"t":[1,null,true]}' | ./$(BIN) '.t|join(",")' 2>&1)" '"1,,true"' "join spells a null member as empty"; \
	assert_out "$$(echo '{"t":{"a":1,"b":2}}' | ./$(BIN) '.t|join(",")' 2>&1)" '"1,2"' "join walks an objects values"; \
	assert_out "$$(echo '{"t":{}}' | ./$(BIN) '.t|join(",")' 2>&1)" '""' "join of an empty object is empty"; \
	assert_out "$$(echo '{"t":["a","b"]}' | ./$(BIN) '.t|join(null)' 2>&1)" '"ab"' "join with a null separator is a no-op"; \
	assert_has "$$(echo '{"t":["a","b"]}' | ./$(BIN) '.t|join(1)' 2>&1)" 'string ("a") and number (1) cannot be added' "join refuses a number separator as jq does"; \
	assert_has "$$(echo '{"t":[[1],[2]]}' | ./$(BIN) '.t|join(",")' 2>&1)" 'string ("") and array ([1]) cannot be added' "join refuses a container member as jq does"; \
	assert_has "$$(echo '{"t":1}' | ./$(BIN) '.t|join(",")' 2>&1)" 'Cannot iterate over number (1)' "join refuses a number input as jq does"; \
	assert_has "$$(echo '{"t":"ab"}' | ./$(BIN) '.t|join(",")' 2>&1)" 'Cannot iterate over string ("ab")' "join refuses a string input as jq does"; \
	assert_code "$$(echo '{"s":"a"}' | ./$(BIN) '.s|startswith' >/dev/null 2>&1; echo $$?)" 2 "startswith without an argument is refused"; \
	assert_code "$$(echo '{"s":"a"}' | ./$(BIN) '.s|startswith("unterminated)' >/dev/null 2>&1; echo $$?)" 2 "an unterminated argument is refused"; \
	assert_code "$$(echo '{"a":' | ./$(BIN) . >/dev/null 2>&1; echo $$?)" 2 "malformed JSON is exit 2"; \
	assert_code "$$(./$(BIN) >/dev/null 2>&1; echo $$?)" 2 "no filter is exit 2"; \
	assert_code "$$(./$(BIN) --help >/dev/null 2>&1; echo $$?)" 0 "help exits 0"; \
	assert_code "$$(./$(BIN) --version >/dev/null 2>&1; echo $$?)" 0 "version exits 0"; \
	assert_out "$$(printf 'null' | ./$(BIN) -c '2|sqrt' 2>/dev/null)" "oojq: filter \"2|sqrt\": \"sqrt\" has no exact answer here for a value that is not a square, and a rounded root would be a wrong answer" "a refusal goes to STDOUT, which is a divergence from jq and is asserted so it stays visible"; \
	assert_out "$$(printf 'null' | ./$(BIN) -c '2|sqrt' 1>/dev/null)" "" "and writes nothing to stderr, because this runtime has no stderr writer at all"; \
	assert_out "$$(printf 'null' | ./$(BIN) --version 2>/dev/null)" "oojq 0.1.1" "and the version is on stdout, as it is in jq"; \
	assert_out "$$(./$(BIN) .name $(TMPDOC) 2>&1 | tr '\n' '|')" '"oojq"|' "reads a named file"; \
	assert_out "$$(./$(BIN) .name $(TMPDOC) 2>&1 | md5sum)" "$$(echo '$(DOC)' | ./$(BIN) .name 2>&1 | md5sum)" "file and stdin agree byte for byte"; \
	assert_out "$$(run '.' | md5sum)" "$$(run '.' | md5sum)" "double run is byte identical"; \
	assert_out "$$(run '.tags[]' | md5sum)" "$$(run '.tags[]' | md5sum)" "double run is byte identical under iteration"; \
	assert_out "$$(echo '{"t":["a","b","c"]}' | ./$(BIN) -c '.t|map(.)' 2>&1)" '["a","b","c"]' "map gathers into one array"; \
	assert_out "$$(echo '{"t":["a","b","c"]}' | ./$(BIN) -c '.t|map(length)' 2>&1)" '[1,1,1]' "map of a computed value"; \
	assert_out "$$(echo '{"t":[3,1,2,1]}' | ./$(BIN) -c '.t|sort' 2>&1)" '[1,1,2,3]' "sort orders numbers"; \
	assert_out "$$(echo '{"t":[3,1,2,1]}' | ./$(BIN) -c '.t|unique' 2>&1)" '[1,2,3]' "unique dedupes numbers"; \
	assert_out "$$(echo '{"t":["c","a","b","a"]}' | ./$(BIN) -c '.t|group_by(.)' 2>&1)" '[["a","a"],["b"],["c"]]' "group_by over strings"; \
	assert_out "$$(echo '{"t":["a","b"]}' | ./$(BIN) -c '.t|join("-")' 2>&1)" '"a-b"' "join takes a literal separator"; \
	assert_out "$$(echo 'null' | ./$(BIN) 'range(3)' 2>&1 | tr '\n' '|')" '0|1|2|' "range counts up from zero"; \
	assert_out "$$(echo 'null' | ./$(BIN) 'range(1;4)' 2>&1 | tr '\n' '|')" '1|2|3|' "range with a start"; \
	assert_out "$$(echo 'null' | ./$(BIN) 'range(5;0;-1)' 2>&1 | tr '\n' '|')" '5|4|3|2|1|' "range with a negative step"; \
	assert_out "$$(echo 'null' | ./$(BIN) -c '[range(3)]' 2>&1)" '[0,1,2]' "range collected into an array"; \
	assert_out "$$(echo '{"n":2}' | ./$(BIN) '.n>1' 2>&1)" 'true' "a comparison needs no surrounding space"; \
	assert_out "$$(echo '{"n":2}' | ./$(BIN) '.n>=2 and .n<=2' 2>&1)" 'true' "and binds looser than comparison"; \
	assert_out "$$(echo '{"a":1,"b":2}' | ./$(BIN) -c '.a==1 or .b==9' 2>&1)" 'true' "or keeps the truthy side"; \
	assert_out "$$(echo '{"a":1,"b":2}' | ./$(BIN) -c '.a==9 and .b==9' 2>&1)" 'false' "and of two falsehoods"; \
	assert_out "$$(echo '{"t":[1,2,3]}' | ./$(BIN) -c '.t|to_entries' 2>&1)" '[{"key":0,"value":1},{"key":1,"value":2},{"key":2,"value":3}]' "to_entries on an array keys by index"; \
	assert_out "$$(echo '{"a":1.5}' | ./$(BIN) '.a+1' 2>&1)" '2.5' "a float adds exactly"; \
	assert_out "$$(echo '{"a":1.5}' | ./$(BIN) '.a|floor' 2>&1)" '1' "floor of a decimal"; \
	assert_out "$$(echo '{"a":-2.5}' | ./$(BIN) '.a|abs' 2>&1)" '2.5' "abs of a negative decimal"; \
	assert_out "$$(echo '{"a":1}' | ./$(BIN) -c '[.a,.a,.a]|add' 2>&1)" '3' "add over a collected array"; \
	assert_out "$$(echo '{"t":[1,2,3]}' | ./$(BIN) -c '[.t[]|select(.>1)]' 2>&1)" '[2,3]' "select without spaces around the operator"; \
	assert_out "$$(echo '{"t":[]}' | ./$(BIN) -c '[.t[]|select(.>1)]' 2>&1)" '[]' "select over empty"; \
	assert_out "$$(echo '{"t":[1.5,2.5]}' | ./$(BIN) '.t|join("|")' 2>&1)" '"1.5|2.5"' "join spells a float member"; \
	assert_out "$$(echo '{"a":[1,"x",null,true,[2]]}' | ./$(BIN) -c '[.a[]|numbers]' 2>&1)" '[1]' "numbers selects the value in hand"; \
	assert_out "$$(echo '{"a":[1,"x",null,true,[2]]}' | ./$(BIN) -c '[.a[]|arrays]' 2>&1)" '[[2]]' "arrays selects containers"; \
	assert_out "$$(echo '{"a":[1,"x",null,true,[2]]}' | ./$(BIN) -c '[.a[]|scalars]' 2>&1)" '[1,"x",null,true]' "scalars leaves containers out"; \
	assert_out "$$(echo '{"a":[1,"x",null,true,[2]]}' | ./$(BIN) -c '[.a[]|iterables]' 2>&1)" '[[2]]' "iterables keeps containers"; \
	assert_out "$$(echo '{"n":null}' | ./$(BIN) -c '[.n|values]' 2>&1)" '[]' "values drops a null"; \
	assert_out "$$(echo '{"o":{"z":1,"a":2}}' | ./$(BIN) -c '.o|keys_unsorted' 2>&1)" '["z","a"]' "keys_unsorted is source order"; \
	assert_out "$$(echo '{"t":["a"]}' | ./$(BIN) -c 'keys_unsorted' 2>&1)" '["t"]' "keys_unsorted on the document"; \
	assert_out "$$(echo '{"i":[[1,2],[3],[]]}' | ./$(BIN) -c '.i|flatten' 2>&1)" '[1,2,3]' "flatten drops an empty array as jq does"; \
	assert_out "$$(echo '{"i":[[1,[2]]]}' | ./$(BIN) -c '.i|flatten(1)' 2>&1)" '[1,[2]]' "flatten to a depth of one"; \
	assert_out "$$(echo '{"i":[[1,2]]}' | ./$(BIN) -c '.i|flatten(0)' 2>&1)" '[[1,2]]' "flatten to a depth of none"; \
	assert_out "$$(echo '{"o":{"a":1}}' | ./$(BIN) -c '.o|tojson' 2>&1)" '"{\"a\":1}"' "tojson writes one line"; \
	assert_out "$$(echo 'null' | ./$(BIN) -c '"[1,2]"|fromjson' 2>&1)" '[1,2]' "fromjson reads a string"; \
	assert_out "$$(printf '%s' '{"s":"{\"a\":1}"}' | ./$(BIN) -c '.s|fromjson' 2>&1)" '{"a":1}' "fromjson reads an object"; \
	assert_out "$$(echo 'null' | ./$(BIN) -c '0|gmtime' 2>&1)" '[1970,0,1,0,0,0,4,0]' "gmtime reads the epoch, month from zero and weekday from Sunday"; \
	assert_out "$$(echo 'null' | ./$(BIN) -c '951782400|gmtime' 2>&1)" '[2000,1,29,0,0,0,2,59]' "gmtime finds a leap day, 29 February 2000"; \
	assert_out "$$(echo 'null' | ./$(BIN) -c '(-1)|gmtime' 2>&1)" '[1969,11,31,23,59,59,3,364]' "and a second before the epoch is the day before at the end of it"; \
	assert_out "$$(echo 'null' | ./$(BIN) -c '1500000000|gmtime|mktime' 2>&1)" '1500000000' "mktime is the inverse of gmtime"; \
	assert_out "$$(echo 'null' | ./$(BIN) -c '[2000,0,1,0,0,0,99,999]|mktime' 2>&1)" '946684800' "and mktime ignores the weekday and day-of-year it is handed"; \
	assert_out "$$(echo 'null' | ./$(BIN) -c '0|todate' 2>&1)" '"1970-01-01T00:00:00Z"' "todate writes ISO text"; \
	assert_out "$$(echo 'null' | ./$(BIN) -c '1500000000.7|todate' 2>&1)" '"2017-07-14T02:40:00Z"' "and a fraction of a second is dropped, as in jq"; \
	assert_out "$$(echo 'null' | ./$(BIN) -c '"1970-01-01T00:00:00Z"|fromdate' 2>&1)" '0' "fromdate reads ISO text back"; \
	assert_out "$$(echo 'null' | ./$(BIN) -c '"2021-3-4T05:06:07Z"|fromdate' 2>&1)" '1614834367' "and a month or day of one digit still parses, as in jq"; \
	assert_has "$$(echo 'null' | ./$(BIN) -c '"notadate"|fromdate' 2>&1)" 'does not match format' "fromdate refuses a string that is not a date"; \
	assert_out "$$(echo 'null' | ./$(BIN) -c '"1970-01-01T00:00:00Z"|fromdateiso8601' 2>&1)" '0' "fromdateiso8601 reads ISO text back"; \
	assert_out "$$(echo 'null' | ./$(BIN) -c '"2021-3-4T05:06:07Z"|fromdateiso8601' 2>&1)" '1614834367' "fromdateiso8601 reads short month and day"; \
	assert_has "$$(echo 'null' | ./$(BIN) -c '"notadate"|fromdateiso8601' 2>&1)" 'does not match format' "fromdateiso8601 refuses a string that is not a date"; \
	assert_has "$$(echo 'null' | ./$(BIN) -c '"x"|gmtime' 2>&1)" 'gmtime() requires numeric inputs' "gmtime names the kind it was refused on, as jq does"; \
	assert_out "$$(echo 'null' | ./$(BIN) -c '[2015,2,5,14,30,25]|strftime("%Y-%m-%dT%H:%M:%S")' 2>&1)" '"2015-03-05T14:30:25"' "strftime writes the fields it is given"; \
	assert_out "$$(echo 'null' | ./$(BIN) -c '[2015,2,5,14,30,25]|strftime("%Y|%y|%C|%m|%d|%e|%j|%H|%I|%M|%S|%p|%a|%A|%b|%B|%u|%w|%U|%W|%G|%V|%z|%Z")' 2>&1)" '"2015|15|20|03|05| 5|064|14|02|30|25|PM|Thu|Thursday|Mar|March|4|4|09|09|2015|10|+0000|GMT"' "strftime answers every base code at once, and %Y is unpadded"; \
	assert_out "$$(echo 'null' | ./$(BIN) -c '[2015,2,5,14,30,25]|strftime("%c|%D|%F|%R|%T|%r|%x|%X")' 2>&1)" '"Thu 05 Mar 2015 02:30:25 PM GMT|03/05/15|2015-03-05|14:30|14:30:25|02:30:25 PM|03/05/2015|02:30:25 PM"' "the eight composites, with %X as the clock and a half, as jq spells it"; \
	assert_out "$$(echo 'null' | ./$(BIN) -c '[2015,2,5]|strftime("%F %T")' 2>&1)" '"2015-03-05 00:00:00"' "a composite keeps its place in the format, before the text that follows it"; \
	assert_out "$$(echo 'null' | ./$(BIN) -c '[2015,2,5]|strftime("a%Yb%Tc%")' 2>&1)" '"a2015b00:00:00c%"' "and so does a composite between two runs of plain text"; \
	assert_out "$$(echo 'null' | ./$(BIN) -c '[2015,2,5]|strftime("%c%c")' 2>&1)" '"Thu 05 Mar 2015 12:00:00 AM GMTThu 05 Mar 2015 12:00:00 AM GMT"' "a composite repeated twice is expanded twice"; \
	assert_out "$$(echo 'null' | ./$(BIN) -c '[]|strftime("%F %T")' 2>&1)" '"1899-12-31 00:00:00"' "an empty array is the zeroed struct, so 1900 less a day"; \
	assert_out "$$(echo 'null' | ./$(BIN) -c '[2015]|strftime("%F %T")' 2>&1)" '"2014-12-31 00:00:00"' "and a missing month and day are January and the day before the first"; \
	assert_out "$$(echo 'null' | ./$(BIN) -c '[-1]|strftime("%F")' 2>&1)" '"-2-12-31"' "a year of -1 is a year of -2 once the day before the first is taken off it"; \
	assert_out "$$(echo 'null' | ./$(BIN) -c '[2015,13,5]|strftime("%Y-%m-%d")' 2>&1)" '"2016-02-05"' "a month past December rolls into the next year"; \
	assert_out "$$(echo 'null' | ./$(BIN) -c '[2015,12,32]|strftime("%Y-%m-%d")' 2>&1)" '"2016-02-01"' "and so does a day past the end of a month"; \
	assert_out "$$(echo 'null' | ./$(BIN) -c '[2015,2,5,25,0,0]|strftime("%F %T")' 2>&1)" '"2015-03-06 01:00:00"' "an hour of 25 is one o'clock the next day"; \
	assert_out "$$(echo 'null' | ./$(BIN) -c '[2015,2,5,0,0,-1]|strftime("%F %T")' 2>&1)" '"2015-03-04 23:59:59"' "and a second of -1 is the last second of the day before"; \
	assert_out "$$(echo 'null' | ./$(BIN) -c '[2015,2,5,0,-90,0]|strftime("%F %T")' 2>&1)" '"2015-03-04 22:30:00"' "and a negative minute borrows from the hour and the day"; \
	assert_out "$$(echo 'null' | ./$(BIN) -c '[2015,2,5,0,0,0,9,9]|strftime("%F %T %a %j")' 2>&1)" '"2015-03-05 00:00:00 Thu 064"' "strftime ignores the weekday and day-of-year it is handed"; \
	assert_out "$$(echo 'null' | ./$(BIN) -c '[2015.7,2,5]|strftime("%F %T")' 2>&1)" '"2015-03-05 00:00:00"' "a float in a slot truncates, as it does in todate"; \
	assert_out "$$(echo 'null' | ./$(BIN) -c '0|strftime("%F %T %a %j %z %Z")' 2>&1)" '"1970-01-01 00:00:00 Thu 001 +0000 GMT"' "a number is seconds since the epoch, and reads in UTC"; \
	assert_out "$$(echo 'null' | ./$(BIN) -c '1425565825|strftime("%F %T %a %j")' 2>&1)" '"2015-03-05 14:30:25 Thu 064"' "so a number and the array gmtime makes of it agree"; \
	assert_out "$$(echo 'null' | ./$(BIN) -c '-1|strftime("%F %T")' 2>&1)" '"1969-12-31 23:59:59"' "a number one second below the epoch is the day before at the end of it"; \
	assert_out "$$(echo 'null' | ./$(BIN) -c '1.9999|strftime("%F %T")' 2>&1)" '"1970-01-01 00:00:01"' "a fraction of a second truncates toward zero"; \
	assert_out "$$(echo 'null' | ./$(BIN) -c '1e15|strftime("%Y")' 2>&1)" '"31690708"' "a year too large for a C int is still written out in full"; \
	assert_out "$$(echo 'null' | ./$(BIN) -c '[2016,0,1]|strftime("%G %V")' 2>&1)" '"2015 53"' "ISO week 53 of the year before, because the Thursday is in December"; \
	assert_out "$$(echo 'null' | ./$(BIN) -c '[2017,0,1]|strftime("%G %V")' 2>&1)" '"2016 52"' "and a Sunday 1 January is the last week of the year before"; \
	assert_out "$$(echo 'null' | ./$(BIN) -c '[2018,11,31]|strftime("%G %V")' 2>&1)" '"2019 01"' "and a Monday 31 December is week one of the year after"; \
	assert_out "$$(echo 'null' | ./$(BIN) -c '[2020,11,31]|strftime("%G %V")' 2>&1)" '"2020 53"' "a leap year ends on ISO week 53"; \
	assert_out "$$(echo 'null' | ./$(BIN) -c '[1,0,1]|strftime("%Y %C %y")' 2>&1)" '"1 0 01"' "years before the common era keep the century and wrap the two digits"; \
	assert_out "$$(echo 'null' | ./$(BIN) -c '[500,0,1]|strftime("%Y %y")' 2>&1)" '"500 00"' "a year of 500 is not padded and its two digits are 00"; \
	assert_out "$$(echo 'null' | ./$(BIN) -c '[-1,0,1]|strftime("%y %C")' 2>&1)" '"99 -1"' "a year of -1 is year 99 of a century of -1"; \
	assert_out "$$(echo 'null' | ./$(BIN) -c '[10000,0,1]|strftime("%Y %j")' 2>&1)" '"10000 001"' "a year of 10000 is written out and the day of the year is 001"; \
	assert_out "$$(echo 'null' | ./$(BIN) -c '[2015,2,5,0,0,0]|strftime("%I %p %H")' 2>&1)" '"12 AM 00"' "midnight is twelve in the morning"; \
	assert_out "$$(echo 'null' | ./$(BIN) -c '[2015,2,5,12,0,0]|strftime("%I %p %H")' 2>&1)" '"12 PM 12"' "and noon is twelve in the afternoon"; \
	assert_out "$$(echo 'null' | ./$(BIN) -c '[2015,2,5]|strftime("%Q")' 2>&1)" '"%Q"' "a code jq does not know is written out as it stands"; \
	assert_out "$$(echo 'null' | ./$(BIN) -c '[2015,2,5]|strftime("%")' 2>&1)" '"%"' "a percent with nothing after it stands for itself"; \
	assert_out "$$(echo 'null' | ./$(BIN) -c '[2015,2,5]|strftime("a%")' 2>&1)" '"a%"' "and so does one at the end of a run of text"; \
	assert_out "$$(echo 'null' | ./$(BIN) -c '[2015,2,5]|strftime("%%")' 2>&1)" '"%"' "a doubled percent is one percent"; \
	assert_out "$$(echo 'null' | ./$(BIN) -c '[2015,2,5]|strftime("")' 2>&1)" '""' "an empty format writes an empty string"; \
	assert_has "$$(echo 'null' | ./$(BIN) -c '"x"|strftime("%F")' 2>&1)" 'strftime/1 requires parsed datetime inputs' "strftime refuses a value that is not a date, in jq's words"; \
	assert_has "$$(echo 'null' | ./$(BIN) -c '[2015,"x"]|strftime("%F")' 2>&1)" 'strftime/1 requires parsed datetime inputs' "strftime refuses a slot that is not a number, in jq's words"; \
	assert_has "$$(echo 'null' | ./$(BIN) -c '[2015,2,5]|strftime(1)' 2>&1)" 'strftime/1 requires a string format' "strftime refuses a format that is not a string, in jq's words"; \
	assert_has "$$(echo 'null' | ./$(BIN) -c '[2015,2,5]|strftime("%F %s")' 2>&1)" 'strftime format code %s needs the local UTC offset' "strftime refuses %s, which jq answers in the machine's own timezone"; \
	assert_has "$$(echo 'null' | ./$(BIN) -c '[2015,2,5]|strftime("%Y","%m")' 2>&1)" 'takes one value, and the argument written gives several' "strftime refuses a format written as a generator, like index and contains"; \
	assert_has "$$(echo 'null' | ./$(BIN) -c '[2015,2,5]|strftime' 2>&1)" '"strftime" needs a literal argument' "strftime refuses to be written with no format at all"; \
	assert_out "$$(echo 'null' | ./$(BIN) -c '"2015-03-05"|strptime("%Y-%m-%d")' 2>&1)" '[2015,2,5,0,0,0,4,63]' "strptime reads the canonical date back"; \
	assert_out "$$(echo 'null' | ./$(BIN) -c '"2015-03-05T14:30:25Z"|strptime("%Y-%m-%dT%H:%M:%SZ")' 2>&1)" '[2015,2,5,14,30,25,4,63]' "and the same with a clock and a zone"; \
	assert_out "$$(echo 'null' | ./$(BIN) -c '"2015-03-05T14:30:25+00:00"|strptime("%Y-%m-%dT%H:%M:%S%z")' 2>&1)" '[2015,2,5,14,30,25,4,63]' "with the offset written in the RFC 3339 way"; \
	assert_out "$$(echo 'null' | ./$(BIN) -c '"2015-03-05"|strptime("%F")' 2>&1)" '[2015,2,5,0,0,0,4,63]' "%F is %Y-%m-%d, and reads a one digit month"; \
	assert_out "$$(echo 'null' | ./$(BIN) -c '"2015-3-5"|strptime("%F")' 2>&1)" '[2015,2,5,0,0,0,4,63]' "a one digit month and day are the same date"; \
	assert_out "$$(echo 'null' | ./$(BIN) -c '"2015-03-05 14:30:25"|strptime("%F %T")' 2>&1)" '[2015,2,5,14,30,25,4,63]' "two composites in one format, in the order they were written"; \
	assert_out "$$(echo 'null' | ./$(BIN) -c '"2015-03-05T14:30:25Z"|strptime("%FT%TZ")' 2>&1)" '[2015,2,5,14,30,25,4,63]' "and with no separator between them"; \
	assert_out "$$(echo 'null' | ./$(BIN) -c '"03/05/15"|strptime("%D")' 2>&1)" '[2015,2,5,0,0,0,4,63]' "%D is %m/%d/%y, so two digits of a century"; \
	assert_out "$$(echo 'null' | ./$(BIN) -c '"03/05/15"|strptime("%x")' 2>&1)" '[15,2,5,0,0,0,4,63]' "%x is %m/%d/%Y, which is the one table that differs, and gives 15"; \
	assert_out "$$(echo 'null' | ./$(BIN) -c '"03/05/2015"|strptime("%x")' 2>&1)" '[2015,2,5,0,0,0,4,63]' "%x takes a full year where %D would not"; \
	assert_out "$$(echo 'null' | ./$(BIN) -c '"15-03-05"|strptime("%y-%m-%d")' 2>&1)" '[2015,2,5,0,0,0,4,63]' "%y is two digits of a year, pivoted at 69"; \
	assert_out "$$(echo 'null' | ./$(BIN) -c '"68"|strptime("%y")' 2>&1)" '[2068,0,0,0,0,0,6,-1]' "so 68 is this century"; \
	assert_out "$$(echo 'null' | ./$(BIN) -c '"69"|strptime("%y")' 2>&1)" '[1969,0,0,0,0,0,2,-1]' "and 69 is the last"; \
	assert_out "$$(echo 'null' | ./$(BIN) -c '"20 15"|strptime("%C %y")' 2>&1)" '[2015,0,0,0,0,0,3,-1]' "%C writes the century outright"; \
	assert_out "$$(echo 'null' | ./$(BIN) -c '"19 99"|strptime("%C %y")' 2>&1)" '[1999,0,0,0,0,0,4,-1]' "and a %y after it overwrites the century"; \
	assert_out "$$(echo 'null' | ./$(BIN) -c '"2015"|strptime("%Y")' 2>&1)" '[2015,0,0,0,0,0,3,-1]' "a bare %Y leaves the day of the year at minus one, the day before the first"; \
	assert_out "$$(echo 'null' | ./$(BIN) -c '"Mar"|strptime("%b")' 2>&1)" '[1900,2,0,0,0,0,3,58]' "a bare %b is enough to place the day of the year"; \
	assert_out "$$(echo 'null' | ./$(BIN) -c '"March 5 2015"|strptime("%B %d %Y")' 2>&1)" '[2015,2,5,0,0,0,4,63]' "a full month name reads as well as its first three letters"; \
	assert_out "$$(echo 'null' | ./$(BIN) -c '"December 5 2015"|strptime("%B %d %Y")' 2>&1)" '[2015,11,5,0,0,0,6,338]' "and the longest name is not cut to three letters"; \
	assert_out "$$(echo 'null' | ./$(BIN) -c '"Thu, 05 Mar 2015 14:30:25 GMT"|strptime("%a, %d %b %Y %H:%M:%S %Z")' 2>&1)" '[2015,2,5,14,30,25,4,63]' "the whole of an RFC 822 date, in words"; \
	assert_out "$$(echo 'null' | ./$(BIN) -c '"Thursday, 05 December 2015 14:30:25 GMT"|strptime("%A, %d %B %Y %H:%M:%S %Z")' 2>&1)" '[2015,11,5,14,30,25,4,338]' "with every name spelled out"; \
	assert_out "$$(echo 'null' | ./$(BIN) -c '"2015-03-05T14:30:25+0000"|strptime("%Y-%m-%dT%H:%M:%S%z")' 2>&1)" '[2015,2,5,14,30,25,4,63]' "an offset of four digits and no colon"; \
	assert_out "$$(echo 'null' | ./$(BIN) -c '"2015-03-05T14:30:25+05:30"|strptime("%Y-%m-%dT%H:%M:%S%z")' 2>&1)" '[2015,2,5,14,30,25,4,63]' "and of two, a colon, and two"; \
	assert_out "$$(echo 'null' | ./$(BIN) -c '"2015 064"|strptime("%Y %j")' 2>&1)" '[2015,2,5,0,0,0,4,63]' "a day of the year is a month and a day when the year is named"; \
	assert_out "$$(echo 'null' | ./$(BIN) -c '"2015 366"|strptime("%Y %j")' 2>&1)" '[2015,24,31,0,0,0,5,365]' "a day past the end of the year is jq's month of 24 and its last day"; \
	assert_out "$$(echo 'null' | ./$(BIN) -c '"1900 366"|strptime("%Y %j")' 2>&1)" '[1900,24,31,0,0,0,2,365]' "and the weekday still comes from the real date, which is in the next year"; \
	assert_out "$$(echo 'null' | ./$(BIN) -c '"2016 366"|strptime("%Y %j")' 2>&1)" '[2016,11,31,0,0,0,6,365]' "in a leap year the 366th day is an ordinary December 31"; \
	assert_out "$$(echo 'null' | ./$(BIN) -c '"366 2016"|strptime("%j %Y")' 2>&1)" '[2016,11,31,0,0,0,6,365]' "the day of the year sees a year written after it"; \
	assert_out "$$(echo 'null' | ./$(BIN) -c '"2015 064 9"|strptime("%Y %j %d")' 2>&1)" '[2015,2,9,0,0,0,1,63]' "%j fills in the month and %d the day, whichever is written first"; \
	assert_out "$$(echo 'null' | ./$(BIN) -c '"2015 9 064"|strptime("%Y %d %j")' 2>&1)" '[2015,2,9,0,0,0,1,63]' "and the same two the other way round give the same date"; \
	assert_out "$$(echo 'null' | ./$(BIN) -c '"2015 12 031"|strptime("%Y %m %j")' 2>&1)" '[2015,11,31,0,0,0,4,30]' "a month named leaves %j to fill in only the day"; \
	assert_out "$$(echo 'null' | ./$(BIN) -c '"2015 12 366"|strptime("%Y %m %j")' 2>&1)" '[2015,11,31,0,0,0,4,365]' "and a day past that month clamps to its last day"; \
	assert_out "$$(echo 'null' | ./$(BIN) -c '"2015 7"|strptime("%Y %u")' 2>&1)" '[2015,0,0,0,0,0,0,-1]' "%u counts seven days to Sunday, and Sunday is zero"; \
	assert_out "$$(echo 'null' | ./$(BIN) -c '"2015 6"|strptime("%Y %w")' 2>&1)" '[2015,0,0,0,0,0,6,-1]' "%w counts from Sunday already"; \
	assert_out "$$(echo 'null' | ./$(BIN) -c '"2015-03-05T14:30:25Z"|strptime("%Y-%m-%dT%H:%M:%SZ")|strftime("%F %T")' 2>&1)" '"2015-03-05 14:30:25"' "what strptime reads, strftime writes"; \
	assert_out "$$(echo 'null' | ./$(BIN) -c '"2015-03-05T14:30:25Z"|strptime("%Y-%m-%dT%H:%M:%SZ")|mktime' 2>&1)" '1425565825' "and it is the same instant mktime made"; \
	assert_out "$$(echo 'null' | ./$(BIN) -c '"2015-03-05T14:30:25Z"|strptime("%Y-%m-%dT%H:%M:%SZ")|mktime|strftime("%F %T %Z %z")' 2>&1)" '"2015-03-05 14:30:25 GMT +0000"' "so a read and a write round trip through the epoch"; \
	assert_out "$$(echo 'null' | ./$(BIN) -c '"2015- 3- 5"|strptime("%Y-%m-%d")' 2>&1)" '[2015,2,5,0,0,0,4,63]' "a numeric directive skips the blanks in front of it"; \
	assert_out "$$(echo 'null' | ./$(BIN) -c '"2015-03-05 14:30:25 GMT"|strptime("%F %T %Z")' 2>&1)" '[2015,2,5,14,30,25,4,63]' "a zone name runs to the next blank"; \
	assert_has "$$(echo 'null' | ./$(BIN) -c '"14:30:25"|strptime("%H:%M:%S")' 2>&1)" 'names no date' "a format naming no date is refused, because jq leaves the weekday and the yearday as its C stack held it"; \
	assert_has "$$(echo 'null' | ./$(BIN) -c '"14"|strptime("%H")' 2>&1)" 'names no date' "and so is a format naming only a clock, the same way"; \
	assert_has "$$(echo 'null' | ./$(BIN) -c '"2015 extra"|strptime("%Y")' 2>&1)" 'leaves " extra" unread' "unread text is refused, where jq answers with a ninth element holding a string"; \
	assert_has "$$(echo 'null' | ./$(BIN) -c '"2015-03-05 extra"|strptime("%F")' 2>&1)" 'leaves " extra" unread' "and the same through a composite"; \
	assert_has "$$(echo 'null' | ./$(BIN) -c '"13:30:25"|strptime("%X")' 2>&1)" 'does not match format' "an hour %I cannot hold is refused, where jq answers a ninth element"; \
	assert_has "$$(echo 'null' | ./$(BIN) -c '"02015"|strptime("%Y")' 2>&1)" 'leaves "5" unread' "a year is four digits wide, so the fifth is left over and refused"; \
	assert_has "$$(echo 'null' | ./$(BIN) -c '"2015-03-05x"|strptime("%Y-%m-%d")' 2>&1)" 'leaves "x" unread' "a literal that does not match leaves the rest of the text unread"; \
	assert_has "$$(echo 'null' | ./$(BIN) -c '"2015-03-05"|strptime("%c")' 2>&1)" 'does not match format' "%c cannot be read back, so it is refused the way jq refuses it"; \
	assert_has "$$(echo 'null' | ./$(BIN) -c '"2015"|strptime("%%")' 2>&1)" 'does not match format' "a doubled percent is not a directive when reading"; \
	assert_has "$$(echo 'null' | ./$(BIN) -c '"2015"|strptime("%Q")' 2>&1)" 'does not match format' "and neither is a code jq does not know";  echo $$pass $$fail >> $(CNT);
	@$(SUITE_FNS) \
	assert_has "$$(echo 'null' | ./$(BIN) -c '"2015-03-05"|strptime' 2>&1)" 'needs a literal argument' "strptime will not do without a format"; \
	assert_has "$$(echo 'null' | ./$(BIN) -c '"2015-03-05"|strptime("%Y-%m-%d","%H")' 2>&1)" 'takes one value' "and a format written as a generator is refused, like index and contains"; \
	assert_has "$$(echo 'null' | ./$(BIN) -c '1|strptime("%Y")' 2>&1)" 'requires string inputs' "a number is not text to read"; \
	assert_has "$$(echo 'null' | ./$(BIN) -c '"2015-03-05"|strptime(1)' 2>&1)" 'requires string inputs' "and a format that is not a string is not a format"; \
	assert_out "$$(echo 'null' | ./$(BIN) -c '"abcabc"|indices("b")' 2>&1)" '[1,4]' "indices finds every place, not just the first"; \
	assert_out "$$(echo 'null' | ./$(BIN) -c '"abcabc"|indices("bc")' 2>&1)" '[1,4]' "and every place a longer needle sits"; \
	assert_out "$$(echo 'null' | ./$(BIN) -c '"abcabc"|indices("a")' 2>&1)" '[0,3]' "including the first"; \
	assert_out "$$(echo 'null' | ./$(BIN) -c '"abcabc"|indices("z")' 2>&1)" '[]' "a needle that is not there is an empty answer and not a null one"; \
	assert_out "$$(echo 'null' | ./$(BIN) -c '"abcabc"|indices("")' 2>&1)" '[]' "and so is an empty needle"; \
	assert_out "$$(echo 'null' | ./$(BIN) -c '"abc"|indices("abc")' 2>&1)" '[0]' "a needle as long as the text matches once"; \
	assert_out "$$(echo 'null' | ./$(BIN) -c '"aaaa"|indices("aa")' 2>&1)" '[0,1,2]' "overlaps count, because the scan steps one character at a time"; \
	assert_out "$$(echo 'null' | ./$(BIN) -c '"aaa"|indices("aa")' 2>&1)" '[0,1]' "so a shorter text overlaps too"; \
	assert_out "$$(echo 'null' | ./$(BIN) -c '"ababab"|indices("abab")' 2>&1)" '[0,2]' "and the last overlap is found as well"; \
	assert_out "$$(echo 'null' | ./$(BIN) -c '[1,2,1,2]|indices(1)' 2>&1)" '[0,2]' "over an array it is every member equal to the needle"; \
	assert_out "$$(echo 'null' | ./$(BIN) -c '[1,2,1,2]|indices(2)' 2>&1)" '[1,3]' "for the last value as well as the first"; \
	assert_out "$$(echo 'null' | ./$(BIN) -c '[1,2,3]|indices(9)' 2>&1)" '[]' "and a member that is not there is empty"; \
	assert_out "$$(echo 'null' | ./$(BIN) -c '[]|indices(1)' 2>&1)" '[]' "an empty array has no members to find"; \
	assert_out "$$(echo 'null' | ./$(BIN) -c '["ab","cd","ab"]|indices("ab")' 2>&1)" '[0,2]' "an array of strings is searched by value"; \
	assert_out "$$(echo 'null' | ./$(BIN) -c '[{"a":1},{"a":1}]|indices({"a":1})' 2>&1)" '[0,1]' "and an object member compares by value"; \
	assert_out "$$(echo 'null' | ./$(BIN) -c '[{"a":[1]},{"a":[1]}]|indices({"a":[1]})' 2>&1)" '[0,1]' "even when the object holds an array"; \
	assert_out "$$(echo 'null' | ./$(BIN) -c '[null,null]|indices(null)' 2>&1)" '[0,1]' "a null needle is a needle like any other"; \
	assert_out "$$(echo 'null' | ./$(BIN) -c 'null|indices("a")' 2>&1)" 'null' "a null input is null, as it is for index"; \
	assert_out "$$(echo 'null' | ./$(BIN) -c '[1,null]|index(null)' 2>&1)" '1' "and a null needle over an array still finds the null"; \
	assert_out "$$(echo 'null' | ./$(BIN) -c '"abcabc"|index("b")' 2>&1)" '1' "index is indices with a first answer"; \
	assert_out "$$(echo 'null' | ./$(BIN) -c '"abcabc"|rindex("b")' 2>&1)" '4' "and rindex with a last one"; \
	assert_out "$$(echo 'null' | ./$(BIN) -c '[1,2,1,2]|index(1)' 2>&1)" '0' "over an array as well"; \
	assert_out "$$(echo 'null' | ./$(BIN) -c '[1,2,1,2]|rindex(1)' 2>&1)" '2' "for the last one too"; \
	assert_out "$$(echo 'null' | ./$(BIN) -c '"héllo"|indices("l")' 2>&1)" '[2,3]' "a search is counted in characters and not in bytes"; \
	assert_out "$$(echo 'null' | ./$(BIN) -c '"日本語"|indices("本")' 2>&1)" '[1]' "three wide characters and still one index"; \
	assert_out "$$(echo 'null' | ./$(BIN) -c '""|split("b")' 2>&1)" '[]' "an empty string split on a non empty separator is no pieces and not one empty piece"; \
	assert_out "$$(echo 'null' | ./$(BIN) -c '""|split("")' 2>&1)" '[]' "and an empty separator over an empty string agrees as well"; \
	assert_out "$$(echo 'null' | ./$(BIN) -c '"a"|split("a")' 2>&1)" '["",""]' "a separator that is the whole text gives the two empty ends"; \
	assert_out "$$(echo 'null' | ./$(BIN) -c '"abc"|split("d")' 2>&1)" '["abc"]' "a separator that is not there leaves the text whole"; \
	assert_out "$$(echo 'null' | ./$(BIN) -c '1|"abc"|startswith("b")' 2>&1)" 'false' "a pipeline hands startswith the string, not the number it started from"; \
	assert_out "$$(echo 'null' | ./$(BIN) -c 'null|"abc"|endswith("b")' 2>&1)" 'false' "and endswith the same, which is why the number before the pipe is not refused"; \
	assert_out "$$(echo 'null' | ./$(BIN) -c '[1]|"abc"|test("b")' 2>&1)" 'true' "and test matches a string that arrived through a pipe from an array"; \
	assert_out "$$(echo 'null' | ./$(BIN) -c '"abc"|split("b")' 2>&1)" '["a","c"]' "a string needle against a string still splits"; \
	assert_out "$$(echo 'null' | ./$(BIN) -c '"abc"|split("")' 2>&1)" '["a","b","c"]' "and an empty separator still splits into characters"; \
	assert_out "$$(echo 'null' | ./$(BIN) -c '"abc"|startswith("a")' 2>&1)" 'true' "a matching prefix is still true"; \
	assert_out "$$(echo 'null' | ./$(BIN) -c '"abc"|startswith("z")' 2>&1)" 'false' "and a non matching one is still false"; \
	assert_out "$$(echo 'null' | ./$(BIN) -c '"abc"|endswith("c")' 2>&1)" 'true' "as is a matching suffix"; \
	assert_out "$$(echo 'null' | ./$(BIN) -c '"abc"|ltrimstr("a")' 2>&1)" '"bc"' "a prefix is still trimmed"; \
	assert_out "$$(echo 'null' | ./$(BIN) -c '"abc"|ltrimstr("z")' 2>&1)" '"abc"' "and a prefix that is not there leaves the text alone"; \
	assert_out "$$(echo 'null' | ./$(BIN) -c '"abc"|rtrimstr("c")' 2>&1)" '"ab"' "a suffix is still trimmed"; \
	assert_out "$$(echo 'null' | ./$(BIN) -c '"abc"|test("b")' 2>&1)" 'true' "test still matches"; \
	assert_out "$$(echo 'null' | ./$(BIN) -c '"abc"|test("z")' 2>&1)" 'false' "and still does not match"; \
	assert_out "$$(echo 'null' | ./$(BIN) -c '"héllo"|startswith("hé")' 2>&1)" 'true' "a multi character prefix is compared in characters"; \
	assert_out "$$(echo 'null' | ./$(BIN) -c '"日本語"|split("本")' 2>&1)" '["日","語"]' "and a wide separator splits at the right place"; \
	assert_has "$$(echo 'null' | ./$(BIN) -c '"abc"|startswith(1)' 2>&1)" 'startswith() requires string inputs' "a number needle against a string is refused in jq's words"; \
	assert_has "$$(echo 'null' | ./$(BIN) -c '"abc"|endswith(1)' 2>&1)" 'endswith() requires string inputs' "and one for endswith"; \
	assert_has "$$(echo 'null' | ./$(BIN) -c '"abc"|ltrimstr(1)' 2>&1)" 'startswith() requires string inputs' "ltrimstr borrows the sentence of the startswith it is built from"; \
	assert_has "$$(echo 'null' | ./$(BIN) -c '"abc"|rtrimstr(1)' 2>&1)" 'endswith() requires string inputs' "and rtrimstr the one of endswith"; \
	assert_has "$$(echo 'null' | ./$(BIN) -c '"abc"|split(1)' 2>&1)" 'split input and separator must be strings' "split names its own operation"; \
	assert_has "$$(echo 'null' | ./$(BIN) -c '"abc"|index(1)' 2>&1)" 'Cannot index string with number' "index names the indexing rule instead"; \
	assert_has "$$(echo 'null' | ./$(BIN) -c '"abc"|rindex(1)' 2>&1)" 'Cannot index string with number' "as does rindex"; \
	assert_has "$$(echo 'null' | ./$(BIN) -c '"abc"|indices(1)' 2>&1)" 'Cannot index string with number' "and indices"; \
	assert_has "$$(echo 'null' | ./$(BIN) -c '"abc"|indices(null)' 2>&1)" 'Cannot index string with null' "for a null needle as well"; \
	assert_has "$$(echo 'null' | ./$(BIN) -c '"abc"|test(1)' 2>&1)" 'number not a string or array' "test names the kind it was given rather than the operation"; \
	assert_has "$$(echo 'null' | ./$(BIN) -c '"abc"|test(true)' 2>&1)" 'boolean not a string or array' "for a boolean needle as well"; \
	assert_has "$$(echo 'null' | ./$(BIN) -c '"abc"|test(1.5)' 2>&1)" 'number not a string or array' "and for a float, which jq also calls a number"; \
	assert_has "$$(echo 'null' | ./$(BIN) -c '1|startswith("b")' 2>&1)" 'startswith() requires string inputs' "a string needle against a number is refused too"; \
	assert_has "$$(echo 'null' | ./$(BIN) -c 'null|endswith("b")' 2>&1)" 'endswith() requires string inputs' "as is one against a null"; \
	assert_has "$$(echo 'null' | ./$(BIN) -c '[1]|test("b")' 2>&1)" 'cannot be matched, as it is not a string' "and test over an array, with the value named in the sentence"; \
	assert_has "$$(echo 'null' | ./$(BIN) -c '[1,2]|contains(1)' 2>&1)" 'cannot have their containment checked' "contains keeps its own refusal, which was already right"; \
	assert_has "$$(echo 'null' | ./$(BIN) -c '"abc"|index' 2>&1)" 'needs a literal argument' "a builtin jq has no zero argument form of is refused rather than answering null"; \
	assert_has "$$(echo 'null' | ./$(BIN) -c '"abc"|indices' 2>&1)" 'needs a literal argument' "and so is the new one"; \
	assert_has "$$(echo 'null' | ./$(BIN) -c '"abc"|split' 2>&1)" 'needs a literal argument' "as are the rest of the string operations"; \
	assert_has "$$(echo 'null' | ./$(BIN) -c '"abc"|startswith' 2>&1)" 'needs a literal argument' "one by one, with the name in the sentence"; \
	assert_has "$$(echo 'null' | ./$(BIN) -c '"abc"|test' 2>&1)" 'needs a literal argument' "including test"; \
	assert_has "$$(echo 'null' | ./$(BIN) -c '"abcabc"|indices("a","b")' 2>&1)" 'takes one value' "a needle written as a generator is refused, as it is for index and contains"; \
	assert_has "$$(echo 'null' | ./$(BIN) -c '[1,2]|indices(1,2)' 2>&1)" 'takes one value' "and over an array as well"; \
	assert_has "$$(echo 'null' | ./$(BIN) -c '{"a":1}|indices("a")' 2>&1)" 'is not supported' "an object is refused, because jq gives three answers there and not one rule"; \
	assert_has "$$(echo 'null' | ./$(BIN) -c '"abc"|test(["b"])' 2>&1)" 'needs a scalar literal argument' "an array needle is a missing feature and is still refused for not being a scalar"; \
	assert_out "$$(echo 'null' | ./$(BIN) -c 'null|index("a")' 2>&1)" 'null' "a null input answers null for a string needle"; \
	assert_out "$$(echo 'null' | ./$(BIN) -c 'null|index(1)' 2>&1)" 'null' "and for a number needle"; \
	assert_out "$$(echo 'null' | ./$(BIN) -c 'null|index(1.5)' 2>&1)" 'null' "and for a float, which is a number too"; \
	assert_out "$$(echo 'null' | ./$(BIN) -c 'null|index({})' 2>&1)" 'null' "and for an object, which reads as a name"; \
	assert_out "$$(echo 'null' | ./$(BIN) -c 'null|rindex("a")' 2>&1)" 'null' "rindex is the same shape"; \
	assert_out "$$(echo 'null' | ./$(BIN) -c 'null|rindex(1)' 2>&1)" 'null' "for a number as well"; \
	assert_out "$$(echo 'null' | ./$(BIN) -c 'null|indices("a")' 2>&1)" 'null' "and indices is too"; \
	assert_out "$$(echo 'null' | ./$(BIN) -c 'null|indices(1)' 2>&1)" 'null' "for a number"; \
	assert_out "$$(echo 'null' | ./$(BIN) -c '[1,null]|index(null)' 2>&1)" '1' "a null needle finds the null in an array"; \
	assert_out "$$(echo 'null' | ./$(BIN) -c '[1,null]|rindex(null)' 2>&1)" '1' "for rindex as well"; \
	assert_out "$$(echo 'null' | ./$(BIN) -c '[1,null]|indices(null)' 2>&1)" '[1]' "and indices finds it as well"; \
	assert_out "$$(echo 'null' | ./$(BIN) -c '[1]|index(1)' 2>&1)" '0' "an array is searched by value and not by position"; \
	assert_out "$$(echo 'null' | ./$(BIN) -c '[]|index(1)' 2>&1)" 'null' "and an empty array has no member for index to find"; \
	assert_out "$$(echo 'null' | ./$(BIN) -c '[[1]]|index(1)' 2>&1)" 'null' "and a member that is itself an array never matches"; \
	assert_out "$$(echo 'null' | ./$(BIN) -c '[1,2,3]|add' 2>&1)" '6' "add sums the members"; \
	assert_out "$$(echo 'null' | ./$(BIN) -c '[]|add' 2>&1)" 'null' "an empty array sums to null"; \
	assert_out "$$(echo 'null' | ./$(BIN) -c '[1,2]|add' 2>&1)" '3' "and two members sum to three"; \
	assert_out "$$(echo 'null' | ./$(BIN) -c '["a","b"]|add' 2>&1)" '"ab"' "strings do not sum and are refused rather than answered"; \
	assert_out "$$(echo 'null' | ./$(BIN) -c '[[1,2],[3]]|add' 2>&1)" '[1,2,3]' "nor do arrays, which jq also refuses"; \
	assert_out "$$(echo 'null' | ./$(BIN) -c '{"a":1}|add' 2>&1)" '1' "an object sums its values"; \
	assert_out "$$(echo 'null' | ./$(BIN) -c '[1,2,3]|add(.)' 2>&1)" '[1,2,3]' "add reads its filter as a collect of the whole input, not a member sum"; \
	assert_out "$$(echo 'null' | ./$(BIN) -c '[]|add(.)' 2>&1)" '[]' "an empty input collects the filter once and sums a one member array"; \
	assert_out "$$(echo 'null' | ./$(BIN) -c '[[1,2],[3]]|add(length)' 2>&1)" '2' "a body that answers a number is summed, not the members"; \
	assert_out "$$(echo 'null' | ./$(BIN) -c '[1,2]|add(1)' 2>&1)" '1' "a literal filter is a filter as well"; \
	assert_out "$$(echo 'null' | ./$(BIN) -c '1|add("b")' 2>&1)" '"b"' "a string body over a scalar is collected too"; \
	assert_out "$$(echo 'null' | ./$(BIN) -c '[1,2,3]|add(.[])' 2>&1)" '6' "a body that iterates collects the members it walked"; \
	assert_out "$$(echo 'null' | ./$(BIN) -c '[1,2]|add(.[0], .[1])' 2>&1)" '3' "a top level comma is one argument holding a generator"; \
	assert_out "$$(echo 'null' | ./$(BIN) -c '[1,2,3]|add(empty)' 2>&1)" 'null' "an empty collect is an empty array, and an empty array sums to null"; \
	assert_out "$$(echo 'null' | ./$(BIN) -c '[1,2,3]|add(.[] | .+1)' 2>&1)" '9' "a body with a pipe collects the values it piped"; \
	assert_out "$$(echo 'null' | ./$(BIN) -c '[range(0;5)]|add(.)' 2>&1)" '[0,1,2,3,4]' "a collect of the whole input is that input, one member"; \
	assert_out "$$(echo 'null' | ./$(BIN) -c '[[1],[2]]|add(.)' 2>&1)" '[[1],[2]]' "one member of an array is the array, so nothing is summed away"; \
	assert_has "$$(echo 'null' | ./$(BIN) -c '[1,2,3]|add(.;.)' 2>&1)" 'add/2' "a semicolon is a second argument and jq has no add/2"; \
	assert_has "$$(printf 'null' | ./$(BIN) 'length("x")' 2>&1)" 'length/1 is not defined' "length takes no argument in jq, so a body after it is refused"; \
	assert_has "$$(printf 'null' | ./$(BIN) 'tostring("x")' 2>&1)" 'tostring/1 is not defined' "tostring takes no argument in jq, so a body after it is refused"; \
	assert_has "$$(printf 'null' | ./$(BIN) 'tonumber("x")' 2>&1)" 'tonumber/1 is not defined' "tonumber takes no argument in jq, so a body after it is refused"; \
	assert_has "$$(printf 'null' | ./$(BIN) 'type("x")' 2>&1)" 'type/1 is not defined' "type takes no argument in jq, so a body after it is refused"; \
	assert_has "$$(printf 'null' | ./$(BIN) 'keys("x")' 2>&1)" 'keys/1 is not defined' "keys takes no argument in jq, so a body after it is refused"; \
	assert_has "$$(printf 'null' | ./$(BIN) 'sort("x")' 2>&1)" 'sort/1 is not defined' "sort takes no argument in jq, so a body after it is refused"; \
	assert_has "$$(printf 'null' | ./$(BIN) 'reverse("x")' 2>&1)" 'reverse/1 is not defined' "reverse takes no argument in jq, so a body after it is refused"; \
	assert_has "$$(printf 'null' | ./$(BIN) 'unique("x")' 2>&1)" 'unique/1 is not defined' "unique takes no argument in jq, so a body after it is refused"; \
	assert_has "$$(printf 'null' | ./$(BIN) 'floor("x")' 2>&1)" 'floor/1 is not defined' "floor takes no argument in jq, so a body after it is refused"; \
	assert_has "$$(printf 'null' | ./$(BIN) 'sqrt("x")' 2>&1)" 'sqrt/1 is not defined' "sqrt takes no argument in jq, so a body after it is refused"; \
	assert_has "$$(printf 'null' | ./$(BIN) 'tojson("x")' 2>&1)" 'tojson/1 is not defined' "tojson takes no argument in jq, so a body after it is refused"; \
	assert_has "$$(printf 'null' | ./$(BIN) 'values("x")' 2>&1)" 'values/1 is not defined' "values takes no argument in jq, so a body after it is refused"; \
	assert_out "$$(printf 'null' | ./$(BIN) -c '[1]|first(1)' 2>&1)" '1' "first still takes a body, and the arity guard does not touch it"; \
	assert_out "$$(printf 'null' | ./$(BIN) -c '[1]|last(1)' 2>&1)" '1' "and last does not either"; \
	assert_out "$$(printf 'null' | ./$(BIN) -c '[1]|map(1+0)' 2>&1)" '[1]' "nor map"; \
	assert_out "$$(printf 'null' | ./$(BIN) -c '[1]|any(true)' 2>&1)" 'true' "nor any"; \
	assert_out "$$(printf 'null' | ./$(BIN) -c '[1]|sort_by(.)' 2>&1)" '[1]' "nor sort_by"; \
	assert_out "$$(printf 'null' | ./$(BIN) -c 'true|contains(true)' 2>&1)" 'true' "a boolean contains itself"; \
	assert_out "$$(printf 'null' | ./$(BIN) -c 'false|contains(false)' 2>&1)" 'true' "and the other boolean contains itself"; \
	assert_has "$$(printf 'null' | ./$(BIN) -c 'true|contains(false)' 2>&1)" 'cannot have their containment checked' "but neither contains the other"; \
	assert_has "$$(printf 'null' | ./$(BIN) -c 'false|contains(true)' 2>&1)" 'cannot have their containment checked' "in either direction"; \
	assert_has "$$(printf 'null' | ./$(BIN) -c '1 as $x | $x' 2>&1)" 'binding a variable with "as" is not supported' "as after an expression is refused by name, as it is at the start of a filter"; \
	assert_has "$$(printf 'null' | ./$(BIN) -c '1 reduce . as $x (0;.)' 2>&1)" '"reduce" is not supported' "and so is every other reserved word wherever it turns up"; \
	assert_has "$$(printf 'null' | ./$(BIN) -c '1 def f: 1; f' 2>&1)" '"def" is not supported' "def among them"; \
	assert_has "$$(printf 'null' | ./$(BIN) -c '1 foreach . as $x (0;.)' 2>&1)" '"foreach" is not supported' "foreach among them"; \
	assert_has "$$(printf 'null' | ./$(BIN) -c '1 label $out | 1' 2>&1)" '"label" is not supported' "label among them"; \
	assert_has "$$(printf 'null' | ./$(BIN) -c '1 import "x" as y; 1' 2>&1)" '"import" is not supported' "and import, which is the one that names a file rather than a construct"; \
	assert_has "$$(printf 'null' | ./$(BIN) -c '1 try .' 2>&1)" '"try" is not supported' "and try, which keeps pointing at the question mark instead"; \
	assert_has "$$(printf 'null' | ./$(BIN) -c '1 2' 2>&1)" 'unexpected' "a leftover that is not a reserved word keeps the generic parse error"; \
	assert_has "$$(printf 'null' | ./$(BIN) -c '.a b' 2>&1)" 'unexpected' "so a real syntax error is not hidden behind a sentence about a feature"; \
	assert_has "$$(echo '{"a":1}' | ./$(BIN) '.a //= 9' 2>&1)" 'right hand side eagerly' "//= is refused, and the refusal names why rather than saying it is unimplemented"; \
	assert_has "$$(echo '{"a":1}' | ./$(BIN) '.a //= empty' 2>&1)" 'answers nothing' "because jq answers nothing there and a rewrite to |= would answer 1"; \
	assert_has "$$(echo '{"a":1}' | ./$(BIN) '.a //= 9' 2>&1)" 'silently wrong' "and the same rewrite is silently wrong for an impure right hand side"; \
	assert_out "$$(echo '{"a":1}' | ./$(BIN) -c '.a |= (. // 9)' 2>&1)" '{"a":1}' "so the |= spelling is the one this build does support"; \
	assert_out "$$(echo '{"a":1,"b":null}' | ./$(BIN) -c '.b |= (. // 9)' 2>&1)" '{"a":1,"b":9}' "and it fills a null the way jq fills it"; \
	assert_out "$$(echo '{"a":1,"d":0,"e":""}' | ./$(BIN) -c '.d |= (. // 9)' 2>&1)" '{"a":1,"d":0,"e":""}' "leaving a zero alone, because zero is truthy in jq"; \
	assert_out "$$(echo '{"a":1,"e":""}' | ./$(BIN) -c '.e |= (. // 9)' 2>&1)" '{"a":1,"e":""}' "and an empty string, for the same reason"; \
	assert_has "$$(echo 'null' | ./$(BIN) -c 'null|index(true)' 2>&1)" 'Cannot index null with boolean' "a boolean needle over a null is refused"; \
	assert_has "$$(echo 'null' | ./$(BIN) -c 'null|index(null)' 2>&1)" 'Cannot index null with null' "and so is a null needle"; \
	assert_has "$$(echo 'null' | ./$(BIN) -c 'null|index([])' 2>&1)" 'Cannot index null with array' "and an array needle"; \
	assert_has "$$(echo 'null' | ./$(BIN) -c 'null|rindex(true)' 2>&1)" 'Cannot index null with boolean' "the same for rindex"; \
	assert_has "$$(echo 'null' | ./$(BIN) -c 'null|indices(true)' 2>&1)" 'Cannot index null with boolean' "and for indices"; \
	assert_has "$$(echo 'null' | ./$(BIN) -c '"abc"|index(1)' 2>&1)" 'Cannot index string with number' "a number needle over a string is refused"; \
	assert_has "$$(echo 'null' | ./$(BIN) -c '"abc"|indices(1)' 2>&1)" 'Cannot index string with number' "for indices as well"; \
	assert_has "$$(echo 'null' | ./$(BIN) -c '"abc"|startswith(1)' 2>&1)" 'startswith() requires string inputs' "and startswith names its own operation"; \
	assert_has "$$(echo 'null' | ./$(BIN) -c '"abc"|split(1)' 2>&1)" 'split input and separator must be strings' "as does split"; \
	assert_has "$$(echo 'null' | ./$(BIN) -c '"abc"|test(1)' 2>&1)" 'number not a string or array' "and test names the kind it was given"; \
	assert_out "$$(echo '{"s":"abc"}' | ./$(BIN) -c '.s|explode' 2>&1)" '[97,98,99]' "explode is code points"; \
	assert_out "$$(echo 'null' | ./$(BIN) -c '[104,105]|implode' 2>&1)" '"hi"' "implode is the inverse"; \
	assert_out "$$(echo '{"s":"abc"}' | ./$(BIN) -c '.s|index("b")' 2>&1)" '1' "index finds a substring"; \
	assert_out "$$(echo '{"s":"abcb"}' | ./$(BIN) -c '.s|rindex("b")' 2>&1)" '3' "rindex finds the last one"; \
	assert_out "$$(echo '{"s":"abc"}' | ./$(BIN) -c '.s|index("z")' 2>&1)" 'null' "index reports a miss as null"; \
	assert_out "$$(printf '%s' '{"s":"héllo"}' | ./$(BIN) -c .s 2>&1)" '"héllo"' "raw UTF-8 survives a round trip"; \
	assert_out "$$(printf '%s' '{"s":"\u00e9"}' | ./$(BIN) -c .s 2>&1)" '"é"' "a two byte escape arrives as UTF-8"; \
	assert_out "$$(printf '%s' '{"s":"\u0041\u00e9\u4e2d"}' | ./$(BIN) -c .s 2>&1)" '"Aé中"' "one two and three byte code points"; \
	assert_out "$$(printf '%s' '{"s":"\ud83d\ude00"}' | ./$(BIN) '.s|length' 2>&1)" '1' "a surrogate pair becomes one character, as jq makes it"; \
	assert_out "$$(printf '%s' '{"s":"x\\u0041y"}' | ./$(BIN) -c .s 2>&1)" '"x\\u0041y"' "an escaped backslash is not an escape"; \
	assert_out "$$(printf '%s' '{"s":"\u0001\u007f"}' | ./$(BIN) -c .s 2>&1)" '"\u0001\u007f"' "a control byte and a delete both escape"; \
	assert_out "$$(printf '%s' '{"s":"\u4e2d"}' | ./$(BIN) -c '.s|explode' 2>&1)" '[20013]' "a three byte code point is one number"; \
	assert_out "$$(printf '%s' '{"s":"\u4e2d"}' | ./$(BIN) '.s|length' 2>&1)" '1' "a three byte code point is one character"; \
	assert_out "$$(echo '{"i":[{"k":"a","n":1},{"k":"a","n":2},{"k":"b","n":3}]}' | ./$(BIN) -c '.i|sort_by(.k)|map(.n)' 2>&1)" '[1,2,3]' "sort_by is stable within a key"; \
	assert_out "$$(echo '{"i":[{"k":"a","n":1},{"k":"a","n":2},{"k":"b","n":3}]}' | ./$(BIN) -c '.i|unique_by(.k)|map(.k)' 2>&1)" '["a","b"]' "unique_by keeps one per key"; \
	assert_out "$$(echo '{"i":[{"k":"a","n":1},{"k":"a","n":2},{"k":"b","n":3}]}' | ./$(BIN) -c '.i|min_by(.k).n' 2>&1)" '1' "min_by takes the first of a tie"; \
	assert_out "$$(echo '{"i":[{"k":"a","n":1},{"k":"a","n":2},{"k":"b","n":3}]}' | ./$(BIN) -c '.i|max_by(.k).n' 2>&1)" '3' "max_by takes the far end"; \
	assert_out "$$(echo '{"i":[]}' | ./$(BIN) -c '.i|min_by(.n)' 2>&1)" 'null' "min_by of empty is null"; \
	assert_out "$$(echo '{"t":["a","b","c"]}' | ./$(BIN) -c '.t|first(.[])' 2>&1)" '"a"' "first takes the first result"; \
	assert_out "$$(echo '{"t":["a","b","c"]}' | ./$(BIN) -c '.t|last(.[])' 2>&1)" '"c"' "last takes the last result"; \
	assert_out "$$(echo '{"t":["a","b"]}' | ./$(BIN) -c '.t|first(.)' 2>&1)" '["a","b"]' "first of a body that answers once keeps the value"; \
	assert_bytes "$$(echo '{"t":["a","b"]}' | ./$(BIN) -c '.t|first(empty)' 2>/dev/null | wc -c)" '0' "first of an empty body writes nothing, as jq does"; \
	assert_bytes "$$(echo '{"t":["a","b"]}' | ./$(BIN) -c '.t|last(empty)' 2>/dev/null | wc -c)" '0' "last of an empty body writes nothing, as jq does"; \
	assert_out "$$(echo '{"t":["a","b"]}' | ./$(BIN) -c '[.t|first(empty)]' 2>&1)" '[]' "an empty first leaves no element behind"; \
	assert_out "$$(echo '{"t":["a","b"]}' | ./$(BIN) -c '.t|first(empty) // "d"' 2>&1)" '"d"' "an empty first falls through an alternative"; \
	assert_out "$$(echo '{"t":null}' | ./$(BIN) -c '.t|first(.)' 2>&1)" 'null' "a body that answers null still answers null"; \
	assert_out "$$(echo '{"t":[]}' | ./$(BIN) -c '.t|first' 2>&1)" 'null' "a bare first on an empty array is still null"; \
	assert_out "$$(echo '{"a":null,"b":1}' | ./$(BIN) -c '.a // .b' 2>&1)" '1' "an alternative reads the right side off the original input"; \
	assert_out "$$(echo '{"a":1,"b":9}' | ./$(BIN) -c '.a // .b' 2>&1)" '1' "a truthy left side settles it"; \
	assert_bytes "$$(echo '{"a":null}' | ./$(BIN) -c '.a // empty' 2>/dev/null | wc -c)" '0' "an empty right side stays empty"; \
	assert_out "$$(echo '1' | ./$(BIN) -c '1 // (2,3)' 2>&1)" '1' "the right side is not run when the left is truthy"; \
	assert_out "$$(echo '1' | ./$(BIN) -c '1 // error("boom")' 2>&1)" '1' "an erroring right side is never reached"; \
	assert_out "$$(echo '1' | ./$(BIN) -c 'empty // 7' 2>&1)" '7' "an empty left side falls through"; \
	assert_out "$$(echo '[1,null,2]' | ./$(BIN) -c '.[] // "d"' 2>&1 | tr '\n' '|')" '1|2|' "falsy values fall out of an alternative"; \
	assert_out "$$(echo '[null,false]' | ./$(BIN) -c '.[] // "d"' 2>&1)" '"d"' "an all falsy left side falls through"; \
	assert_out "$$(echo '1' | ./$(BIN) -c 'null|not' 2>&1)" 'true' "not of null is true"; \
	assert_out "$$(echo '1' | ./$(BIN) -c 'false|not' 2>&1)" 'true' "not of false is true"; \
	assert_out "$$(echo '1' | ./$(BIN) -c 'true|not' 2>&1)" 'false' "not of true is false"; \
	assert_out "$$(echo '1' | ./$(BIN) -c '0|not' 2>&1)" 'false' "zero is truthy, so not is false"; \
	assert_out "$$(echo '1' | ./$(BIN) -c '2|not' 2>&1)" 'false' "not reads a number by truthiness"; \
	assert_out "$$(echo '1' | ./$(BIN) -c '[]|not' 2>&1)" 'false' "an empty array is truthy too"; \
	assert_out "$$(echo '{"k":{}}' | ./$(BIN) -c '.k|not' 2>&1)" 'false' "an empty object is truthy too"; \
	assert_out "$$(echo '1' | ./$(BIN) -c 'error("boom")' 2>&1 | grep -c 'boom')" '1' "error with a string reports that string"; \
	assert_out "$$(echo '1' | ./$(BIN) -c 'error("boom")' 2>&1 | grep -c 'not a string')" '0' "a string error is not wrapped as a value"; \
	assert_out "$$(echo '1' | ./$(BIN) -c 'error' 2>&1 | grep -c '(not a string)')" '1' "a bare error shows the value it was given"; \
	assert_out "$$(echo '1' | ./$(BIN) -c 'error(42)' 2>&1 | grep -c '(not a string): 42')" '1' "a non string error is shown as a value"; \
	assert_out "$$(echo '{"m":"from the doc"}' | ./$(BIN) -c 'error(.m)' 2>&1 | grep -c 'from the doc')" '1' "an error argument may be a filter"; \
	assert_code "$$(echo '1' | ./$(BIN) -c 'error("boom")' >/dev/null 2>&1; echo $$?)" 2 "an error stops with the filter failure status"; \
	assert_out "$$(echo '1' | ./$(BIN) -c '1 // error("never")' 2>&1)" '1' "a truthy left side never reaches an erroring right side"; \
	assert_out "$$(echo '1' | ./$(BIN) -c 'empty // error("boom")' 2>&1 | grep -c 'boom')" '1' "an empty left side does reach the error"; \
	assert_out "$$(printf '%s' '{"s":"héllo"}' | ./$(BIN) -c '.s|utf8bytelength' 2>&1)" '6' "byte length counts bytes, not characters"; \
	assert_out "$$(printf '%s' '{"s":"日本語"}' | ./$(BIN) -c '.s|utf8bytelength' 2>&1)" '9' "three byte characters count three each"; \
	assert_out "$$(printf '%s' '{"s":""}' | ./$(BIN) -c '.s|utf8bytelength' 2>&1)" '0' "an empty string is zero bytes"; \
	assert_out "$$(printf '%s' '{"n":1}' | ./$(BIN) -c '.n|utf8bytelength' 2>&1 | grep -c 'only strings have UTF-8 byte length')" '1' "a number has no byte length, and is named"; \
	assert_out "$$(printf '%s' '{"t":true}' | ./$(BIN) -c '.t|toboolean' 2>&1)" 'true' "a boolean passes through toboolean"; \
	assert_out "$$(printf '%s' '{"s":"x"}' | ./$(BIN) -c '.s|toboolean' 2>&1 | grep -c 'string ("x") cannot be parsed')" '1' "a string is refused by toboolean, quoted the way jq writes it"; \
	assert_out "$$(printf '%s' '{"n":0}' | ./$(BIN) -c '.n|toboolean' 2>&1 | grep -c 'number (0) cannot be parsed')" '1' "zero is not a boolean"; \
	assert_out "$$(printf '%s' '{"n":1.5}' | ./$(BIN) -c '.n|isfinite' 2>&1)" 'true' "a decimal is finite"; \
	assert_out "$$(printf '%s' '{"s":"a"}' | ./$(BIN) -c '.s|isfinite' 2>&1)" 'false' "a string is not a number, so not finite"; \
	assert_out "$$(printf '%s' '{"n":1.5}' | ./$(BIN) -c '.n|isnan' 2>&1)" 'false' "a decimal is not NaN"; \
	assert_out "$$(printf '%s' '{"n":1.5}' | ./$(BIN) -c '.n|isinfinite' 2>&1)" 'false' "a decimal is not infinite"; \
	assert_out "$$(echo '1' | ./$(BIN) -c '"x"|not' 2>&1)" 'false' "a non empty string is truthy"; \
	assert_bytes "$$(echo '1' | ./$(BIN) -c 'empty | []' 2>/dev/null | wc -c)" '0' "an empty stream collected into an array still answers nothing"; \
	assert_out "$$(echo '1' | ./$(BIN) -c '1 // [] | length' 2>&1)" '1' "a truthy left side leaves no second value behind"; \
	assert_out "$$(echo '1' | ./$(BIN) -c '(1,2) | [] | length' 2>&1 | tr '\n' '|')" '0|0|' "a collect answers once per input value"; \
	assert_bytes "$$(echo '{"t":[1,2]}' | ./$(BIN) -c '.t[] | select(.==9) | [.]' 2>/dev/null | wc -c)" '0' "a collect after a select that matched nothing writes nothing"; \
	assert_out "$$(echo '{"t":[1,2]}' | ./$(BIN) -c '[empty]' 2>&1)" '[]' "a body that answers nothing still collects to an empty array"; \
	assert_bytes "$$(echo '{"t":[1,2]}' | ./$(BIN) -c 'empty | [.]' 2>/dev/null | wc -c)" '0' "and the same when the collect is written with a dot"; \
	assert_out "$$(echo '{"t":[1,2]}' | ./$(BIN) -c '.t[] | select(.==1) | [.]' 2>&1)" '[1]' "a collect that matched keeps its value"; \
	assert_out "$$(echo '{"s":"a,b,,c"}' | ./$(BIN) -c '.s|split(",")' 2>&1)" '["a","b","","c"]' "split keeps an empty part"; \
	assert_out "$$(echo '{"s":"abc"}' | ./$(BIN) -c '.s|split(",")' 2>&1)" '["abc"]' "split on an absent separator"; \
	assert_out "$$(echo '{"s":"abc"}' | ./$(BIN) -c '.s|rtrimstr("c")' 2>&1)" '"ab"' "rtrimstr strips a suffix"; \
	assert_code "$$(echo '{"t":["a"]}' | ./$(BIN) '.t|contains([\"a\"])' >/dev/null 2>&1; echo $$?)" 2 "contains with a non scalar argument is refused, not answered false"; \
	assert_out "$$(echo '{"s":"abc"}' | ./$(BIN) -c '.s|rtrimstr("zz")' 2>&1)" '"abc"' "rtrimstr keeps a non matching suffix"; \
	assert_out "$$(echo '{"s":"abc"}' | ./$(BIN) -c '.s|ltrimstr("a")|rtrimstr("c")' 2>&1)" '"b"' "trimming from both ends"; \
	assert_code "$$(printf '{"s":"\\uZZZZ"}' | ./$(BIN) .s >/dev/null 2>&1; echo $$?)" 2 "a malformed escape is refused"; \
	assert_code "$$(printf '%s' '{"s":"a1b2c"}' | ./$(BIN) '.s|splits("[0-9]")' >/dev/null 2>&1; echo $$?)" 2 "splits is refused by name, because the std engine that finds a match is unsafe"; \
	assert_code "$$(printf '%s' '{"s":"aaa"}' | ./$(BIN) '.s|gsub("a"; "b")' >/dev/null 2>&1; echo $$?)" 2 "gsub is refused by name rather than crashing on a non matching pattern"; \
	assert_code "$$(printf '%s' '{"s":"aaa"}' | ./$(BIN) '.s|sub("a"; "b")' >/dev/null 2>&1; echo $$?)" 2 "sub is refused by name too"; \
	assert_out "$$(printf '%s' '{"s":"Hello"}' | ./$(BIN) -c '.s|test("ell")' 2>&1)" 'true' "test still finds a match inside a string"; \
	assert_out "$$(printf '%s' '{"s":"a,b,c"}' | ./$(BIN) -c '.s|split(",")' 2>&1)" '["a","b","c"]' "split is literal and safe where a regex split is not"; \
	assert_has "$$(mcp '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}')" '"protocolVersion":"2024-11-05"' "mcp initialize answers with a protocol version"; \
	assert_has "$$(mcp '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}')" '"name":"oojq"' "mcp initialize names the server"; \
	assert_has "$$(mcp '{"jsonrpc":"2.0","id":2,"method":"tools/list"}')" '"jq_check"' "mcp tools/list advertises jq_check"; \
	assert_has "$$(mcp '{"jsonrpc":"2.0","id":2,"method":"tools/list"}')" '"jq_grammar"' "mcp tools/list advertises jq_grammar"; \
	assert_has "$$(mcp '{"jsonrpc":"2.0","id":2,"method":"tools/list"}')" '"jq"' "mcp tools/list advertises jq"; \
	assert_bytes "$$(mcp '{"jsonrpc":"2.0","method":"notifications/initialized"}' | tr -d '\n' | wc -c)" '0' "an mcp notification gets no reply at all"; \
	assert_out "$$(printf '%s\n%s\n' '{"jsonrpc":"2.0","id":1,"method":"ping"}' '{"jsonrpc":"2.0","id":2,"method":"ping"}' | ./$(BIN) --mcp 2>&1 | grep -c '"result":{}')" '2' "two bare frames in one write are both answered"; \
	assert_out "$$(printf '%s\n%s\n' '{"jsonrpc":"2.0","id":1,"method":"ping"}' '{"jsonrpc":"2.0","id":2,"method":"ping"}' | ./$(BIN) --mcp 2>&1 | grep -c 'truncated')" '0' "consecutive bare frames raise no truncation error"; \
	assert_has "$$(mcp '{"jsonrpc":"2.0","id":7,"method":"tools/call","params":{"name":"jq","arguments":{"filter":".items|map(.id)|add","input":"{\"items\":[{\"id\":1},{\"id\":2},{\"id\":3}]}"}}}')" '6' "the mcp jq tool evaluates a filter"; \
	assert_has "$$(mcp '{"jsonrpc":"2.0","id":8,"method":"tools/call","params":{"name":"jq","arguments":{"filter":".items[","input":"{}"}}}')" 'oojq: filter' "the mcp jq tool refuses a bad filter by name"; \
	assert_has "$$(mcp '{"jsonrpc":"2.0","id":9,"method":"tools/call","params":{"name":"jq_check","arguments":{"filter":".a|map(.)"}}}')" 'accepted' "mcp jq_check accepts a good filter"; \
	assert_has "$$(mcp '{"jsonrpc":"2.0","id":9,"method":"tools/call","params":{"name":"jq_check","arguments":{"filter":".a["}}}')" 'rejected' "mcp jq_check rejects a bad filter"; \
	assert_has "$$(mcp '{"jsonrpc":"2.0","id":15,"method":"tools/call","params":{"name":"jq","arguments":{"filter":".t[]","input":"{\"t\":[1,2,3]}"}}}')" '1' "the mcp jq tool streams every selected value"; \
	assert_out "$$(mcp '{"jsonrpc":"2.0","id":19,"method":"tools/call","params":{"name":"jq","arguments":{"filter":".nope","input":"{}"}}}' | jq -er '.result.content[0].text' 2>/dev/null)" 'null' "an absent member is null over MCP too, as on the command line"; \
	assert_has "$$(mcp '{"jsonrpc":"2.0","id":10,"method":"nosuch"}')" '"code":-32601' "an unknown mcp method is a JSON-RPC error"; \
	assert_has "$$(mcp '{"jsonrpc":"2.0","id":14,"method":"tools/call","params":{"name":"nope"}}')" '"code":-32602' "an unknown mcp tool is a JSON-RPC error"; \
	assert_out "$$(mcp '{"jsonrpc":"2.0","id":14,"method":"tools/call","params":{"name":"nope"}}' | grep -c '"result":{"jsonrpc"')" '0' "a tool error is not wrapped inside a result"; \
	assert_has "$$(mcp '{"jsonrpc":"2.0","id":11,"method":"ping"}')" '"result":{}' "mcp ping answers an empty result"; \
	assert_has "$$(mcp '{"jsonrpc":"2.0","id":12,"method":"tools/call","params":{"name":"jq_grammar"}}')" 'splits sub gsub' "mcp jq_grammar publishes what is refused and why"; \
	mcpbody='{"jsonrpc":"2.0","id":13,"method":"ping"}'; \
	mcplen=$$(printf '%s' "$$mcpbody" | wc -c | tr -d ' '); \
	assert_out "$$(mcp '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}' | jq -e 'has("result")' 2>/dev/null)" 'true' "an mcp reply is valid JSON, checked by a real parser"; \
	assert_out "$$(mcp '{"jsonrpc":"2.0","id":11,"method":"tools/call","params":{"name":"jq","arguments":{"filter":".t[]","input":"{\"t\":[]}"}}}' | jq -e '.result.content[0].text == ""' 2>/dev/null)" 'true' "an empty selection is an empty string, and the reply still parses"; \
	assert_out "$$(mcp '{"jsonrpc":"2.0","id":6,"method":"tools/call","params":{"name":"jq","arguments":{"filter":".a","input":"{\"a\":1}"}}}' | jq -er '.result.content[0].text' 2>/dev/null)" '1' "a tool result text is a JSON string, not a bare value"; \
	assert_out "$$(mcp '{"jsonrpc":"2.0","id":14,"method":"tools/call","params":{"name":"nope"}}' | jq -er '.error.message' 2>/dev/null)" 'unknown tool: nope' "an error message is a JSON string too"; \
	assert_has "$$(printf 'Content-Length: %s\r\n\r\n%s' "$$mcplen" "$$mcpbody" | ./$(BIN) --mcp 2>&1 | tr -d '\r')" 'Content-Length:' "a Content-Length request is answered with a Content-Length frame"; \
	assert_has "$$(printf 'Content-Length: %s\r\n\r\n%s' "$$mcplen" "$$mcpbody" | ./$(BIN) --mcp 2>&1 | tr -d '\r')" '"id":13' "a framed request is answered with the same id"; \
	assert_out "$$(printf '%s' '{"s":"a\"b"}' | ./$(BIN) -c '.s|@json' 2>&1)" '"\"a\\\"b\""' "@json quotes a string as JSON"; \
	assert_out "$$(printf '%s' '{"a":{"b":1}}' | ./$(BIN) -c '.a|@text' 2>&1)" '"{\"b\":1}"' "@text spells a container as compact JSON"; \
	assert_out "$$(printf '%s' '{"t":[1,2]}' | ./$(BIN) -c '.t|tostring' 2>&1)" '"[1,2]"' "tostring spells a container as compact JSON"; \
	assert_out "$$(printf '%s' '{"s":"<a>&q"}' | ./$(BIN) -c '.s|@html' 2>&1)" '"&lt;a&gt;&amp;q"' "@html escapes the markup characters"; \
	assert_out "$$(printf '%s' '{"s":"\u0027"}' | ./$(BIN) -c '.s|@html' 2>&1)" '"&apos;"' "@html escapes a single quote as &apos;, as jq does"; \
	assert_out "$$(printf '%s' '{"n":1}' | ./$(BIN) -c '.n|@html' 2>&1)" '"1"' "@html applies tostring to a number first"; \
	assert_out "$$(printf '%s' '{"a":{"k":1}}' | ./$(BIN) -c '.a|@html' 2>&1)" '"{&quot;k&quot;:1}"' "@html applies tostring to an object first"; \
	assert_out "$$(printf '%s' '{"s":"a b/c"}' | ./$(BIN) -c '.s|@uri' 2>&1)" '"a%20b%2Fc"' "@uri percent encodes outside the unreserved set"; \
	assert_out "$$(printf '%s' '{"s":"-_.~"}' | ./$(BIN) -c '.s|@uri' 2>&1)" '"-_.~"' "@uri leaves the RFC 3986 unreserved set alone"; \
	assert_out "$$(printf '%s' '{"s":"héllo"}' | ./$(BIN) -c '.s|@uri' 2>&1)" '"h%C3%A9llo"' "@uri encodes a multi byte letter one byte at a time"; \
	assert_out "$$(printf '%s' '{"s":"Hello World"}' | ./$(BIN) -c '.s|@base64' 2>&1)" '"SGVsbG8gV29ybGQ="' "@base64 encodes UTF-8 bytes, padded"; \
	assert_out "$$(printf '%s' '{"s":"héllo"}' | ./$(BIN) -c '.s|@base64' 2>&1)" '"aMOpbGxv"' "@base64 encodes a multi byte letter one byte at a time"; \
	assert_out "$$(printf '%s' '{"n":1}' | ./$(BIN) -c '.n|@base64' 2>&1)" '"MQ=="' "@base64 applies tostring to a number first"; \
	assert_out "$$(printf '%s' '{"s":""}' | ./$(BIN) -c '.s|@base64' 2>&1)" '""' "@base64 of nothing is nothing"; \
	assert_out "$$(printf '%s' '{"s":"héllo"}' | ./$(BIN) -c '.s|@base64|@base64d' 2>&1)" '"héllo"' "@base64d undoes @base64 across a multi byte letter"; \
	assert_out "$$(printf '%s' '{"s":"a\"b\\c"}' | ./$(BIN) -c '.s|@base64|@base64d' 2>&1)" '"a\"b\\c"' "@base64d undoes @base64 across quotes and backslashes"; \
	assert_out "$$(printf '%s' '{"a":1}' | ./$(BIN) -c '.a|@base64|@base64d' 2>&1)" '"1"' "@base64 round trips a number"; \
	assert_out "$$(printf '%s' '{"s":"hello"}' | ./$(BIN) -c '.s|@base64|@base64d' 2>&1)" '"hello"' "@base64d decodes a padded string"; \
	assert_out "$$(printf '%s' '{"s":"ab"}' | ./$(BIN) -c '.s|@base64d' 2>&1)" '"i"' "@base64d needs no padding written, as jq does"; \
	assert_out "$$(printf '%s' '{"s":"YQ==="}' | ./$(BIN) -c '.s|@base64d' 2>&1)" '"a"' "@base64d ignores whatever follows the padding"; \
	assert_out "$$(printf '%s' '{"s":"AA=A"}' | ./$(BIN) -c '.s|@base64d' 2>&1)" '"\u0000"' "a pad in the middle ends the run, as jq does"; \
	assert_out "$$(printf '%s' '{"s":"i+/v"}' | ./$(BIN) -c '.s|@base64d|utf8bytelength' 2>&1)" '9' "each byte that cannot start a character becomes its own replacement; jq folds one fewer, and the parity corpus carries that case"; \
	assert_out "$$(printf '%s' '{"s":"/w=="}' | ./$(BIN) -c '.s|@base64d|utf8bytelength' 2>&1)" '3' "a truncated sequence at the end is one replacement, as jq writes it"; \
	assert_has "$$(printf '%s' '{"s":"a"}' | ./$(BIN) '.s|@base64d' 2>&1)" 'trailing base64 byte found' "@base64d says which shape it refused"; \
	assert_has "$$(printf '%s' '{"s":"!!!"}' | ./$(BIN) '.s|@base64d' 2>&1)" 'string ("!!!") is not valid base64 data' "@base64d names the string it was given"; \
	assert_code "$$(printf '%s' '{"s":"a"}' | ./$(BIN) '.s|@base64d' >/dev/null 2>&1; echo $$?)" 2 "@base64d refuses six leftover bits"; \
	assert_code "$$(printf '%s' '{"s":"a-b_"}' | ./$(BIN) '.s|@base64d' >/dev/null 2>&1; echo $$?)" 2 "@base64d refuses the URL-safe spelling, as jq does"; \
	assert_out "$$(printf '%s' '{"t":[false,false]}' | ./$(BIN) -c '.t|any' 2>&1)" 'false' "a bare any is any(.[]), so nothing true is false"; \
	assert_out "$$(printf '%s' '{"t":[true,false]}' | ./$(BIN) -c '.t|all' 2>&1)" 'false' "a bare all is all(.[]), so one false is false"; \
	assert_out "$$(printf '%s' '{"t":[]}' | ./$(BIN) -c '.t|any' 2>&1)" 'false' "any over nothing is false"; \
	assert_out "$$(printf '%s' '{"t":[]}' | ./$(BIN) -c '.t|all' 2>&1)" 'true' "all over nothing is true"; \
	assert_out "$$(printf '%s' '{"t":[[]]}' | ./$(BIN) -c '.t|any' 2>&1)" 'true' "an empty array is truthy, so a bare any sees it"; \
	assert_out "$$(printf '%s' '{"t":[null]}' | ./$(BIN) -c '.t|all' 2>&1)" 'false' "null is falsy, so a bare all refuses it"; \
	assert_out "$$(printf '%s' '{"t":[0,1]}' | ./$(BIN) -c '.t|any' 2>&1)" 'true' "zero is truthy, as jq counts it"; \
	assert_out "$$(printf '%s' '{"o":{"a":true,"b":false}}' | ./$(BIN) -c '.o|any' 2>&1)" 'true' "a bare any over an object reads its values"; \
	assert_out "$$(printf '%s' '{"o":{"a":true,"b":false}}' | ./$(BIN) -c '.o|all' 2>&1)" 'false' "and a bare all over an object too"; \
	assert_out "$$(printf '%s' '{"t":[1,2,3]}' | ./$(BIN) -c '.t|any(.>2)' 2>&1)" 'true' "any with a condition still works"; \
	assert_out "$$(printf '%s' '{"t":[1,2,3]}' | ./$(BIN) -c '.t|all(.>2)' 2>&1)" 'false' "all with a condition still works"; \
	assert_code "$$(printf '%s' '{"t":[1]}' | ./$(BIN) '.t|map' >/dev/null 2>&1; echo $$?)" 2 "map still needs a filter argument"; \
	assert_code "$$(printf '%s' '{"t":[1]}' | ./$(BIN) '.t|select' >/dev/null 2>&1; echo $$?)" 2 "select still needs a filter argument"; \
	assert_code "$$(printf '%s' '{"t":[1]}' | ./$(BIN) '.t|group_by' >/dev/null 2>&1; echo $$?)" 2 "group_by still needs a filter argument"; \
	assert_out "$$(printf '%s' '{"t":["a","b"]}' | ./$(BIN) -c '.t|@csv' 2>&1)" '"\"a\",\"b\""' "@csv writes one row, quoting every string cell"; \
	assert_out "$$(printf '%s' '{"t":[1,null,true]}' | ./$(BIN) -c '.t|@csv' 2>&1)" '"1,,true"' "@csv writes a null cell as empty"; \
	assert_out "$$(printf '%s' '{"t":["a\"b","c,d"]}' | ./$(BIN) -c '.t|@csv' 2>&1)" '"\"a\"\"b\",\"c,d\""' "@csv doubles a quote and leaves a comma alone"; \
	assert_out "$$(printf '%s' '{"t":["a\nb"]}' | ./$(BIN) -c '.t|@csv' 2>&1)" '"\"a\nb\""' "@csv keeps a newline inside the quotes"; \
	assert_out "$$(printf '%s' '{"t":[]}' | ./$(BIN) -c '.t|@csv' 2>&1)" '""' "@csv of an empty row is an empty string"; \
	assert_out "$$(printf '%s' '{"t":[1,2]}' | ./$(BIN) -c '.t|@tsv' 2>&1)" '"1\t2"' "@tsv separates cells with a tab"; \
	assert_out "$$(printf '%s' '{"t":["a\tb","c\\d"]}' | ./$(BIN) -c '.t|@tsv' 2>&1)" '"a\\tb\tc\\\\d"' "@tsv escapes a tab and doubles a backslash"; \
	assert_out "$$(printf '%s' '{"t":["a\nb"]}' | ./$(BIN) -c '.t|@tsv' 2>&1)" '"a\\nb"' "@tsv escapes a newline rather than writing one"; \
	assert_out "$$(printf '%s' '{"t":["héllo"]}' | ./$(BIN) -c '.t|@tsv' 2>&1)" '"héllo"' "@tsv leaves a letter outside ASCII alone"; \
	assert_out "$$(printf '%s' '{"t":["a b"]}' | ./$(BIN) -c '.t|@sh' 2>&1)" '"'"'"'a b'"'"'"' "@sh quotes a word whatever it holds"; \
	word=$$(printf '"%s"' "'it'\\\\''s'"); \
	assert_out "$$(printf '%s' '{"t":["it\u0027s"]}' | ./$(BIN) -c '.t|@sh' 2>&1)" "$$word" "@sh closes and reopens the quote around an apostrophe"; \
	assert_out "$$(printf '%s' '{"t":["a",1,null]}' | ./$(BIN) -c '.t|@sh' 2>&1)" '"'"'"'a'"'"' 1 null"' "@sh writes a number and a null bare, and joins with a space"; \
	assert_out "$$(printf '%s' '{"t":[]}' | ./$(BIN) -c '.t|@sh' 2>&1)" '""' "@sh of no words is an empty string"; \
	assert_has "$$(printf '%s' '{"t":[[1,2]]}' | ./$(BIN) '.t|@csv' 2>&1)" 'is not valid in a csv row' "@csv refuses a nested array by name"; \
	assert_has "$$(printf '%s' '{"t":[[1,2,3,4,5,6,7,8]]}' | ./$(BIN) '.t|@csv' 2>&1)" '2,3,4,5,...' "@csv cuts a long value to eleven bytes, as jq does"; \
	assert_has "$$(printf '%s' '{"t":1}' | ./$(BIN) '.t|@csv' 2>&1)" 'cannot be csv-formatted, only array' "@csv refuses a value that is not an array"; \
	assert_has "$$(printf '%s' '{"t":"x,y"}' | ./$(BIN) '.t|@csv' 2>&1)" 'string ("x,y") cannot be csv-formatted' "@csv names a string the way jq writes it, quotes and all"; \
	assert_has "$$(printf '%s' '{"t":1}' | ./$(BIN) '.t|@tsv' 2>&1)" 'cannot be tsv-formatted, only array' "@tsv says its own name when it refuses"; \
	assert_has "$$(printf '%s' '{"t":[[1,2]]}' | ./$(BIN) '.t|@sh' 2>&1)" 'can not be escaped for shell' "@sh refuses a container rather than spelling it as JSON"; \
	assert_code "$$(printf '%s' '{"t":[[1,2]]}' | ./$(BIN) '.t|@csv' >/dev/null 2>&1; echo $$?)" 2 "@csv refusing a nested array is a filter failure, not a crash"; \
	assert_out "$$(printf '%s' '{"a":{"b":2}}' | ./$(BIN) -c '.a|getpath(["b"])' 2>&1)" '2' "getpath reads a member by name"; \
	assert_out "$$(printf '%s' '{"t":[10,20,30]}' | ./$(BIN) -c '.t|getpath([-1])' 2>&1)" '30' "getpath counts a negative index from the end"; \
	assert_out "$$(printf '%s' '{"t":[10,20,30]}' | ./$(BIN) -c '.t|getpath([9])' 2>&1)" 'null' "getpath past the end is null"; \
	assert_out "$$(printf '%s' '{"t":[10,20,30]}' | ./$(BIN) -c '.t|getpath([-9])' 2>&1)" 'null' "a negative index before the start is null too"; \
	assert_out "$$(printf '%s' '{"a":1}' | ./$(BIN) -c 'getpath([])' 2>&1)" '{"a":1}' "an empty getpath is the value itself"; \
	assert_out "$$(printf '%s' '{"a":{"z":0}}' | ./$(BIN) -c '.a|getpath(["zz"])' 2>&1)" 'null' "a missing member is null"; \
	assert_out "$$(printf '%s' '{"i":[{"k":"a"}]}' | ./$(BIN) -c '.i|getpath([0,"k"])' 2>&1)" '"a"' "getpath mixes an index and a name"; \
	assert_out "$$(printf '%s' '{"t":[[1],[2]]}' | ./$(BIN) -c '.t[]|getpath([0])|type' 2>&1 | tr '\n' '|')" '"number"|"number"|' "getpath walks every value in the stream"; \
	assert_out "$$(printf '%s' '{"t":[10,20,30]}' | ./$(BIN) -c '.t|getpath([0.5])' 2>&1)" '10' "a fractional index truncates toward zero, as jq does"; \
	assert_out "$$(printf '%s' '{"t":[10,20,30]}' | ./$(BIN) -c '.t|getpath([1.9])' 2>&1)" '20' "truncation is toward zero, not rounding"; \
	assert_out "$$(printf '%s' '{"t":[10,20,30]}' | ./$(BIN) -c '.t|getpath([-0.5])' 2>&1)" '10' "a negative fraction truncates to zero, not to the end"; \
	assert_code "$$(printf '%s' '{"a":1}' | ./$(BIN) '.a|getpath([0])' >/dev/null 2>&1; echo $$?)" 2 "getpath refuses to index an object with a number"; \
	assert_code "$$(printf '%s' '{"a":1}' | ./$(BIN) '.a|getpath' >/dev/null 2>&1; echo $$?)" 2 "getpath without an argument is refused by name"; \
	assert_code "$$(printf '%s' '{"a":1}' | ./$(BIN) '.a|getpath("b")' >/dev/null 2>&1; echo $$?)" 2 "getpath needs an array of keys, not a string"; \
	assert_code "$$(printf '%s' '{"a":1}' | ./$(BIN) -e .a >/dev/null 2>&1; echo $$?)" 0 "-e is 0 when a value was printed"; \
	assert_code "$$(printf '%s' '{"a":1}' | ./$(BIN) -e empty >/dev/null 2>&1; echo $$?)" 4 "-e is 4 when nothing was ever produced, the code jq uses"; \
	assert_code "$$(printf '%s' '{"a":null}' | ./$(BIN) -e .a >/dev/null 2>&1; echo $$?)" 1 "-e is 1 when the last value was null"; \
	assert_code "$$(printf '%s' '{"a":false}' | ./$(BIN) -e .a >/dev/null 2>&1; echo $$?)" 1 "-e is 1 when the last value was false"; \
	assert_code "$$(printf '%s' '{"a":1}' | ./$(BIN) -ce .a >/dev/null 2>&1; echo $$?)" 0 "combined short flags are a group, not a filter"; \
	assert_code "$$(printf '%s' '{"a":null}' | ./$(BIN) -ce .a >/dev/null 2>&1; echo $$?)" 1 "-ce is 1 when the last value was null"; \
	assert_code "$$(printf '%s' '{"a":1}' | ./$(BIN) -e -c .a >/dev/null 2>&1; echo $$?)" 0 "separate flags before the filter still work"; \
	assert_code "$$(printf '%s' '{"s":"x"}' | ./$(BIN) -r '.s' >/dev/null 2>&1; echo $$?)" 0 "-r is answered, not refused"; \
	assert_out "$$(printf '%s' '{"s":"a\"b"}' | ./$(BIN) -r '.s' 2>&1)" 'a"b' "-r writes a top level string as its own text"; \
	assert_out "$$(printf '%s' '{"s":"a\tb"}' | ./$(BIN) -r '.s' 2>&1 | tr '\t' 'T')" 'aTb' "-r does not escape a tab, as jq does not"; \
	assert_out "$$(printf '%s' '{"s":"a\nb"}' | ./$(BIN) -r '.s' 2>&1 | tr '\n' 'N')" 'aNbN' "-r does not escape a newline either, so one value spans two lines"; \
	assert_out "$$(printf '%s' '{"n":1}' | ./$(BIN) -r '.n' 2>&1)" '1' "-r leaves a number alone"; \
	assert_out "$$(printf '%s' '{"s":"x"}' | ./$(BIN) -r '.nothing' 2>&1)" 'null' "-r leaves a null alone"; \
	assert_out "$$(printf '%s' '{"o":{"a":1}}' | ./$(BIN) -rc '.o' 2>&1)" '{"a":1}' "-r leaves a container as compact JSON"; \
	assert_out "$$(printf '%s' '{"o":{"a":1}}' | ./$(BIN) -r '.o' 2>&1 | tr '\n' '|')" '{|  "a": 1|}|' "-r leaves a container as pretty JSON"; \
	assert_out "$$(printf '%s' '{"t":["a","b"]}' | ./$(BIN) -r '.t|@csv' 2>&1)" '"a","b"' "-r writes a CSV row as the row and not as a quoted one"; \
	assert_out "$$(printf '%s' '{"t":[1,2]}' | ./$(BIN) -r '.t|@tsv' 2>&1 | tr '\t' 'T')" '1T2' "-r writes a TSV row as the row"; \
	assert_out "$$(printf '%s' '{"t":["a b"]}' | ./$(BIN) -r '.t|@sh' 2>&1)" "'a b'" "-r writes a shell word as the word"; \
	assert_out "$$(printf '%s' '{"t":["a","b"]}' | ./$(BIN) '.t|@csv' 2>&1)" '"\"a\",\"b\""' "and without -r the same row is a JSON string, as in jq"; \
	assert_out "$$(printf '%s' '{"s":"x"}' | ./$(BIN) --raw-output '.s' 2>&1)" 'x' "--raw-output is the long spelling of -r"; \
	assert_out "$$(printf '%s' '{"s":"x"}' | ./$(BIN) -re '.s' 2>&1)" 'x' "-r and -e are one short group, as in jq"; \
	assert_out "$$(printf '%s' '{"s":"a","n":1}' | ./$(BIN) -rc '.s, .n' 2>&1 | tr '\n' '|')" 'a|1|' "-r applies to the whole stream and not to one value"; \
	assert_bytes "$$(printf '%s' '{"s":""}' | ./$(BIN) -r '.s' 2>/dev/null | wc -c)" '1' "-r of an empty string writes an empty line"; \
	assert_out "$$(printf '%s' '0' | ./$(BIN) -c '0|sqrt' 2>&1)" '0' "sqrt of zero is zero"; \
	assert_out "$$(printf '%s' '4' | ./$(BIN) -c '4|sqrt' 2>&1)" '2' "sqrt of a whole square is the whole root"; \
	assert_out "$$(printf '%s' '9' | ./$(BIN) -c '9|sqrt' 2>&1)" '3' "and of a larger one too"; \
	assert_out "$$(printf '%s' '1000000' | ./$(BIN) -c '1000000|sqrt' 2>&1)" '1000' "and of a six digit one"; \
	assert_out "$$(printf '%s' '4.0' | ./$(BIN) -c '4.0|sqrt' 2>&1)" '2' "a whole root prints as a whole, as jq does"; \
	assert_out "$$(printf '%s' '0.25' | ./$(BIN) -c '0.25|sqrt' 2>&1)" '0.5' "sqrt of a decimal square is a decimal root"; \
	assert_out "$$(printf '%s' '2.25' | ./$(BIN) -c '2.25|sqrt' 2>&1)" '1.5' "and of a decimal with two places"; \
	assert_out "$$(printf '%s' '0.0625' | ./$(BIN) -c '0.0625|sqrt' 2>&1)" '0.25' "and of one with four"; \
	assert_out "$$(printf '%s' '0.0001' | ./$(BIN) -c '0.0001|sqrt' 2>&1)" '0.01' "four places of square, two of root"; \
	assert_out "$$(printf '%s' '1e2' | ./$(BIN) -c '1e2|sqrt' 2>&1)" '10' "a written exponent is read before the root is taken"; \
	assert_out "$$(printf '%s' '-4' | ./$(BIN) -c '-4|sqrt' 2>&1)" 'null' "a negative has no real root, and jq writes null"; \
	assert_code "$$(printf '%s' '2' | ./$(BIN) '2|sqrt' >/dev/null 2>&1; echo $$?)" 2 "sqrt of a value that is not a square is refused"; \
	assert_has "$$(printf '%s' '2' | ./$(BIN) '2|sqrt' 2>&1)" 'not a square' "and it says which shape would have worked";  echo $$pass $$fail >> $(CNT);
	@$(SUITE_FNS) \
	assert_code "$$(printf '%s' '0.5' | ./$(BIN) '0.5|sqrt' >/dev/null 2>&1; echo $$?)" 2 "an odd count of decimal places has no decimal root"; \
	assert_code "$$(printf '%s' '10' | ./$(BIN) '10|sqrt' >/dev/null 2>&1; echo $$?)" 2 "ten is not a square and is refused rather than rounded"; \
	assert_has "$$(printf '%s' '"a"' | ./$(BIN) '"a"|sqrt' 2>&1)" 'string ("a") number required' "sqrt names a non number the way jq does"; \
	assert_has "$$(printf '%s' 'true' | ./$(BIN) 'true|sqrt' 2>&1)" 'boolean (true) number required' "and a boolean, called a boolean"; \
	assert_out "$$(printf '%s' '3' | ./$(BIN) -c '(-3)+0' 2>&1)" '-3' "a negative integer keeps its sign through an addition"; \
	assert_out "$$(printf '%s' '3' | ./$(BIN) -c '0-(-3)' 2>&1)" '3' "and subtraction of a negative raises it"; \
	assert_out "$$(printf '%s' '3' | ./$(BIN) -c '(-3)*(-1)' 2>&1)" '3' "and a negative times a negative is positive"; \
	assert_out "$$(printf '%s' '3' | ./$(BIN) -c '(-3)*2' 2>&1)" '-6' "and a negative times a positive is not"; \
	assert_out "$$(printf '%s' '3' | ./$(BIN) -c '(-3)%2' 2>&1)" '-1' "and a remainder keeps the sign of the left side"; \
	assert_out "$$(printf '%s' '3' | ./$(BIN) -c '(-3.5)|floor' 2>&1)" '-4' "floor of a negative decimal rounds away from zero"; \
	assert_out "$$(printf '%s' '3' | ./$(BIN) -c '(-3)|ceil' 2>&1)" '-3' "ceil of a negative whole is itself"; \
	assert_out "$$(printf '%s' '3' | ./$(BIN) -c '(-3.5)|ceil' 2>&1)" '-3' "and of a negative decimal rounds toward zero"; \
	assert_out "$$(printf '%s' '3' | ./$(BIN) -c '(-3.5)|round' 2>&1)" '-4' "and round of a negative half goes the same way as floor"; \
	assert_out "$$(printf '%s' '3' | ./$(BIN) -c '(-0.5)|round' 2>&1)" '-1' "a negative half rounds away from zero, not toward it"; \
	assert_out "$$(printf '%s' '3' | ./$(BIN) -c '(-3)|abs' 2>&1)" '3' "abs of a negative integer is its magnitude"; \
	assert_out "$$(printf '%s' '3' | ./$(BIN) -c '(-3)|fabs' 2>&1)" '3' "fabs of a negative integer is its magnitude"; \
	assert_out "$$(printf '%s' '3' | ./$(BIN) -c '(-3.5)|fabs' 2>&1)" '3.5' "fabs of a negative decimal is its magnitude"; \
	assert_out "$$(printf '%s' '3' | ./$(BIN) -c '(0*-1)|fabs' 2>&1)" '0' "fabs takes a computed negative zero to zero, as jq does"; \
	assert_out "$$(printf '%s' '3' | ./$(BIN) -c '"x"|fabs' 2>&1)" 'oojq: filter ""x"|fabs": fabs needs a number, not a string' "fabs refuses a string and the refusal names fabs, as abs names abs"; \
	assert_out "$$(printf '%s' '3' | ./$(BIN) -c '(-1.5)+(-1.5)' 2>&1)" '-3' "two negative decimals add to a negative whole"; \
	assert_out "$$(printf '%s' '3' | ./$(BIN) -c '(-3) < 0' 2>&1)" 'true' "a negative integer compares below zero"; \
	assert_out "$$(printf '%s' '3' | ./$(BIN) -c '(-3) > 0' 2>&1)" 'false' "and a negative integer does not compare above zero"; \
	assert_out "$$(printf '%s' '3' | ./$(BIN) -c '0 < (-3)' 2>&1)" 'false' "and zero is not below a negative"; \
	assert_out "$$(printf '%s' '3' | ./$(BIN) -c '(-3) < (-2)' 2>&1)" 'true' "two negatives order against each other"; \
	assert_out "$$(printf '%s' '[-3,-2]' | ./$(BIN) -c 'add' 2>&1)" '-5' "add over negatives is negative"; \
	assert_out "$$(printf '%s' '[-3,-2]' | ./$(BIN) -c 'max' 2>&1)" '-2' "max of negatives is the nearer one"; \
	assert_out "$$(printf '%s' '[-3,-2]' | ./$(BIN) -c 'min' 2>&1)" '-3' "and min is the further one"; \
	assert_out "$$(printf '%s' '$(DOC)' | ./$(BIN) -c '.meta.ratio|floor' 2>&1)" '-3' "a negative member of the document floors to itself"; \
	assert_out "$$(printf '%s' '$(DOC)' | ./$(BIN) -c '.meta.ratio+1' 2>&1)" '-2' "and adds as the negative it is"; \
	assert_out "$$(printf '%s' '$(DOC)' | ./$(BIN) -c '.meta.ratio|abs' 2>&1)" '3' "and abs is its magnitude"; \
	assert_out "$$(printf '%s' '$(DOC)' | ./$(BIN) -c '.meta.ratio < 0' 2>&1)" 'true' "and it compares below zero"; \
	assert_out "$$(printf '%s' '$(DOC)' | ./$(BIN) -c '.meta.ratio > 0' 2>&1)" 'false' "and a negative member does not compare above zero"; \
	assert_out "$$(printf '%s' '1' | ./$(BIN) -c '1.5*2' 2>&1)" '3' "a decimal times a whole is exact"; \
	assert_out "$$(printf '%s' '1' | ./$(BIN) -c '2*1.5' 2>&1)" '3' "and a whole times a decimal is the same as the other way round"; \
	assert_out "$$(printf '%s' '1' | ./$(BIN) -c '1.5*1.5' 2>&1)" '2.25' "and two decimals together"; \
	assert_out "$$(printf '%s' '1' | ./$(BIN) -c '0.5*0.5' 2>&1)" '0.25' "and two proper fractions"; \
	assert_out "$$(printf '%s' '1' | ./$(BIN) -c '2.5*4' 2>&1)" '10' "and a decimal that comes out whole"; \
	assert_out "$$(printf '%s' '1' | ./$(BIN) -c '1.5*0' 2>&1)" '0' "and one that is multiplied by nothing"; \
	assert_out "$$(printf '%s' '1' | ./$(BIN) -c '(-1.5)*2' 2>&1)" '-3' "and a negative decimal keeps its sign"; \
	assert_out "$$(printf '%s' '1' | ./$(BIN) -c '(-1.5)*(-2)' 2>&1)" '3' "and two negatives are positive"; \
	assert_out "$$(printf '%s' '1' | ./$(BIN) -c '2*0.5' 2>&1)" '1' "and a whole divided by two, in one step"; \
	assert_out "$$(printf '%s' '1' | ./$(BIN) -c '1000000*0.000001' 2>&1)" '1' "and a million times a millionth"; \
	assert_out "$$(printf '%s' '1' | ./$(BIN) -c '123456789*0.000000001' 2>&1)" '0.12345678900000001' "and a wide one keeps the drift jq has, because 0.000000001 is not exactly a millionth"; \
	assert_out "$$(printf '%s' '1' | ./$(BIN) -c '0.1*0.2' 2>&1)" '0.020000000000000004' "0.1 * 0.2 is 0.020000000000000004 here and in jq, because a float goes through a double"; \
	assert_out "$$(printf '%s' '1' | ./$(BIN) -c '1.23456789*1.23456789' 2>&1)" '1.5241578750190519' "and a square of nine digits rounds the way jq rounds it"; \
	assert_out "$$(printf '%s' '1' | ./$(BIN) -c '2*"a"' 2>&1)" '"aa"' "a string repeats from the right-hand side too"; \
	assert_has "$$(printf '%s' '1' | ./$(BIN) 'null*1' 2>&1)" 'null (null) and number (1) cannot be multiplied' "and a refusal names both sides, as jq does"; \
	assert_has "$$(printf '%s' '1' | ./$(BIN) '[1]*2' 2>&1)" 'array ([1]) and number (2) cannot be multiplied' "and says the kind it found, array included"; \
	assert_out "$$(printf '%s' '1' | ./$(BIN) -c '1+2.25' 2>&1)" '3.25' "a whole plus a wider decimal puts the point where it belongs"; \
	assert_out "$$(printf '%s' '1' | ./$(BIN) -c '2.25+0.1' 2>&1)" '2.35' "and a decimal plus a narrower one"; \
	assert_out "$$(printf '%s' '1' | ./$(BIN) -c '0.5+0.25' 2>&1)" '0.75' "and two proper fractions, where the point moves left"; \
	assert_out "$$(printf '%s' '1' | ./$(BIN) -c '100.5+1.25' 2>&1)" '101.75' "and a wide integer part with a narrow one"; \
	assert_out "$$(printf '%s' '1' | ./$(BIN) -c '1.05+0.5' 2>&1)" '1.55' "and a wide fraction with a narrow one"; \
	assert_out "$$(printf '%s' '1' | ./$(BIN) -c '0.1+0.05' 2>&1)" '0.15000000000000002' "0.1 + 0.05 is 0.15000000000000002 here and in jq, because a float goes through a double"; \
	assert_out "$$(printf '%s' '1' | ./$(BIN) -c '1.1+0.1' 2>&1)" '1.2000000000000002' "and 1.1 + 0.1 is 1.2000000000000002 here and in jq, for the same reason"; \
	assert_out "$$(printf '%s' '1' | ./$(BIN) -c '2.25-0.1' 2>&1)" '2.15' "and the same point rule on subtraction"; \
	assert_out "$$(printf '%s' '1' | ./$(BIN) -c '100.5-0.25' 2>&1)" '100.25' "and on a wide one"; \
	assert_out "$$(printf '%s' '1' | ./$(BIN) -c '0.001+0.002' 2>&1)" '0.003' "and on three places each"; \
	assert_out "$$(printf '%s' '1' | ./$(BIN) -c '10+0.5' 2>&1)" '10.5' "and a two digit integer part with one place"; \
	assert_out "$$(printf '%s' '1' | ./$(BIN) -c '0.5+100' 2>&1)" '100.5' "and a whole plus a decimal does not lose the decimal"; \
	assert_out "$$(printf '%s' '1' | ./$(BIN) -c '1.5+1' 2>&1)" '2.5' "and the case that always worked, still does"; \
	assert_out "$$(jc '1 + .meta.ratio')" '-2|' "a binary operator reads its right side from the input, not the left value"; \
	assert_out "$$(jc '.meta.stars + .meta.ratio')" '39|' "and two members of one object add"; \
	assert_out "$$(jc '.meta.stars * .meta.ratio')" '-126|' "and multiply"; \
	assert_out "$$(jc '.name + .tags[0]')" '"oojqjson"|' "and two strings"; \
	assert_out "$$(jc '.meta.stars == .name')" 'false|' "and compare unequal"; \
	assert_out "$$(jc '.meta.stars > .meta.ratio')" 'true|' "and order"; \
	assert_out "$$(jc '.tags[0] + .name')" '"jsonoojq"|' "and a subscript on the right"; \
	assert_out "$$(printf '%s' '[1,2]' | ./$(BIN) -c '.[0] + .[1]' 2>&1)" '3' "and two subscripts of one array"; \
	assert_out "$$(printf '%s' '[1,2]' | ./$(BIN) -c '.[] + .[]' 2>&1 | tr '\n' '|')" '2|3|3|4|' "and both sides streaming pairs every way, as jq does"; \
	assert_out "$$(printf '%s' '{"a":2,"b":3}' | ./$(BIN) -c '.a + .b' 2>&1)" '5' "the idiom that was never in the corpus"; \
	assert_out "$$(printf '%s' '{"a":2,"b":3}' | ./$(BIN) -c '.a + .a' 2>&1)" '4' "and the same member twice"; \
	assert_out "$$(printf '%s' '{"a":2,"b":3}' | ./$(BIN) -c '.a + (.a + .b)' 2>&1)" '7' "and nested on both sides"; \
	assert_out "$$(jc '[1,2.5]|add')" '3.5|' "add folds with + and no longer drops a decimal"; \
	assert_out "$$(jc '[1.5,2.5]|add')" '4|' "and a whole of decimals"; \
	assert_out "$$(jc '[-1.5,2]|add')" '0.5|' "and a negative among them"; \
	assert_out "$$(jc '[null,1]|add')" '1|' "and a null drops out, as jq's null fold does"; \
	assert_out "$$(jc '[1,null,2]|add')" '3|' "and a null in the middle"; \
	assert_out "$$(jc '[[1],[2]]|add')" '[1,2]|' "and two arrays join"; \
	assert_out "$$(jc '[]|add')" 'null|' "an empty array folds to null, not zero"; \
	assert_out "$$(jc '.tags|add')" '"jsoncli"|' "and an array of strings joins"; \
	assert_out "$$(jc '[1.5,null,2]|add')" '3.5|' "and a decimal either side of a null"; \
	assert_out "$$(jc 'null+1')" '1|' "null plus a number is the number"; \
	assert_out "$$(jc '1+null')" '1|' "and the other way round"; \
	assert_out "$$(jc 'null+null')" 'null|' "and two nulls stay null"; \
	assert_out "$$(jc 'null+[1]')" '[1]|' "and a null before an array"; \
	assert_out "$$(jc '.note + 1')" '1|' "and a null member is the same null"; \
	assert_out "$$(jc '[1.5,2.5]|max')" '2.5|' "max compares decimals, not integer parts"; \
	assert_out "$$(jc '["b","a"]|min')" '"a"|' "and min orders strings"; \
	assert_out "$$(jc '[1,2.5]|max')" '2.5|' "and a mixed array"; \
	assert_out "$$(jc '[null,1]|min')" 'null|' "and null sorts first"; \
	assert_out "$$(jc '["a",1]|min')" '1|' "and a string is above a number"; \
	assert_out "$$(jc '[(0*-1),(0)]|max')" '0|' "max takes the later of two equal values, so this zero is positive"; \
	assert_out "$$(jc '[(0),(0*-1)]|max')" '-0|' "and the same rule leaves a negative zero when it comes last"; \
	assert_out "$$(jc '[(0*-1),(0)]|min')" '-0|' "min keeps the earlier of two equal values instead"; \
	assert_out "$$(jc '[(0),(0*-1)]|min')" '0|' "and the other order gives the other zero"; \
	assert_out "$$(echo '{"a":5}' | ./$(BIN) -c 'if .a>1 then .a else 0 end' 2>&1)" '5' "an if branch reads the input, not the verdict"; \
	assert_out "$$(echo '{"a":5}' | ./$(BIN) -c 'if .a==5 then .a else 0 end' 2>&1)" '5' "and the same when the condition is an equality"; \
	assert_out "$$(echo '{"a":5}' | ./$(BIN) -c 'if (false,true) then "t" else "f" end' 2>&1 | tr '\n' '|')" '"f"|"t"|' "a condition with two answers takes a branch for each"; \
	assert_bytes "$$(echo '{"a":5}' | ./$(BIN) -c 'if (empty) then .a else 0 end' 2>/dev/null | wc -c)" '0' "a condition that answers nothing leaves nothing"; \
	assert_out "$$(echo '{"items":[{"id":1,"k":"a"},{"id":2,"k":"b"}]}' | ./$(BIN) -c '[.items[]|if .id==1 then .k else 0 end]' 2>&1)" '["a",0]' "an if inside an iterate still reads each value"; \
	assert_out "$$(echo '{"a":{"b":1},"c":[2,{"d":3}],"e":null}' | ./$(BIN) -c '[leaf_paths]' 2>&1)" '[["a","b"],["c",0],["c",1,"d"],["e"]]' "leaf_paths names every non-container, and jq has no such builtin"; \
	assert_out "$$(echo '{"x":1}' | ./$(BIN) -c '[leaf_paths]' 2>&1)" '[["x"]]' "leaf_paths on a flat object is every key"; \
	assert_out "$$(printf '%s' '[]' | ./$(BIN) -c '[leaf_paths]' 2>&1)" '[]' "leaf_paths of an empty array is no paths"; \
	assert_out "$$(echo null | ./$(BIN) -c 'def' 2>&1)" 'oojq: filter "def": "def" is not supported in this build' "a reserved word is refused by its own name, not as a typo"; \
	assert_out "$$(echo null | ./$(BIN) -c 'as' 2>&1)" 'oojq: filter "as": binding a variable with "as" is not supported in this build' "as says what it would have needed"; \
	assert_out "$$(echo null | ./$(BIN) -c 'try' 2>&1)" 'oojq: filter "try": "try" is not supported in this build; use ? instead' "and try points at the question mark"; \
	assert_out "$$(echo null | ./$(BIN) -c 'delf' 2>&1)" 'oojq: filter "delf": unknown builtin "delf"; did you mean "del"?' "a real typo still gets its suggestion"; \
	assert_out "$$(printf '%s' '{"import":1,"try":2,"def":3}' | ./$(BIN) -c '.import' 2>&1)" '1' "a reserved word is still a fine field name"; \
	assert_out "$$(printf '%s' '{"items":[1,2,3,4]}' | ./$(BIN) -c 'limit(2; 1,2,3)' 2>&1 | tr '\n' '|')" '1|2|' "limit(2; f) keeps the first two answers of f"; \
	assert_out "$$(printf '%s' '{"items":[1,2,3,4]}' | ./$(BIN) -c 'limit(5; 1,2,3)' 2>&1 | tr '\n' '|')" '1|2|3|' "and a count past the end keeps all of them"; \
	assert_out "$$(printf '%s' '{"items":[1,2,3,4]}' | ./$(BIN) -c '[limit(3; .items[])]' 2>&1)" '[1,2,3]' "limit over an iterate answers them one at a time"; \
	assert_bytes "$$(printf '%s' '{"items":[1,2,3,4]}' | ./$(BIN) -c 'limit(0; 1,2,3)' 2>/dev/null | wc -c)" '0' "a count of zero answers nothing at all"; \
	assert_out "$$(printf '%s' '{"items":[1,2,3,4]}' | ./$(BIN) -c '[limit(2; empty)]' 2>&1)" '[]' "and a body that answers nothing collects as an empty array"; \
	assert_has "$$(printf '%s' '{}' | ./$(BIN) 'limit(2)' 2>&1)" 'limit needs a count and a filter' "limit without a body is refused by name"; \
	assert_has "$$(printf '%s' '{}' | ./$(BIN) 'limit(1,2,3)' 2>&1)" 'limit needs a count and a filter' "and so is one with three arguments"; \
	assert_has "$$(printf '%s' '{}' | ./$(BIN) 'limit(-1; 1)' 2>&1)" 'cannot be negative' "a negative count is refused, as jq refuses it"; \
	assert_has "$$(printf '%s' '{"a":2}' | ./$(BIN) 'limit(.a; 1,2,3)' 2>&1)" 'must be digits written in the filter' "a count that is not digits is refused rather than run without one"; \
	assert_out "$$(printf '%s' '1' | ./$(BIN) -c '[1,2,3][0:5]' 2>&1)" '[1,2,3]' "a slice bound past the end is clamped, not read off the array"; \
	assert_out "$$(printf '%s' '1' | ./$(BIN) -c '[1,2,3][1:99]' 2>&1)" '[2,3]' "and a bound far past it is clamped the same way"; \
	assert_out "$$(printf '%s' '1' | ./$(BIN) -c '[][0:2]' 2>&1)" '[]' "a slice of an empty array is empty, not an out of bounds read"; \
	assert_out "$$(printf '%s' '1' | ./$(BIN) -c '[1,2,3][5:9]' 2>&1)" '[]' "and a window starting past the end is empty too"; \
	assert_out "$$(printf '%s' '1' | ./$(BIN) -c '1.5/0.5' 2>&1)" '3' "a decimal divides exactly now"; \
	assert_out "$$(printf '%s' '1' | ./$(BIN) -c '10/4' 2>&1)" '2.5' "and a whole by four is 2.5"; \
	assert_out "$$(printf '%s' '1' | ./$(BIN) -c '1/8' 2>&1)" '0.125' "and an eighth is exact, where jq is too"; \
	assert_out "$$(printf '%s' '1' | ./$(BIN) -c '0.5/0.25' 2>&1)" '2' "and two fractions"; \
	assert_out "$$(printf '%s' '1' | ./$(BIN) -c '1/0.0001' 2>&1)" '10000' "and a tiny divisor"; \
	assert_out "$$(printf '%s' '1' | ./$(BIN) -c '3.3/1.1' 2>&1)" '2.9999999999999996' "3.3 / 1.1 is the double below 3, as in jq, not the exact 3 a long division gives"; \
	assert_out "$$(printf '%s' '1' | ./$(BIN) -c '3.3/1.1 < 3' 2>&1)" 'true' "and so it really is less than 3, which the exact 3 could not say"; \
	assert_out "$$(printf '%s' '1' | ./$(BIN) -c '3.3/1.1 > 2.9999999999999996' 2>&1)" 'false' "and it is not more than the double just under 3 either"; \
	assert_out "$$(printf '%s' '1' | ./$(BIN) -c '1/3' 2>&1)" '0.3333333333333333' "1 / 3 is the rounded double, as in jq, where the long division used to refuse it"; \
	assert_out "$$(printf '%s' '1' | ./$(BIN) -c '2/3' 2>&1)" '0.6666666666666666' "and so is 2 / 3 for the same reason"; \
	assert_out "$$(printf '%s' '1' | ./$(BIN) -c '5.5%2' 2>&1)" '1' "5.5 % 2 is 1, because jq truncates both sides before the remainder"; \
	assert_out "$$(printf '%s' '1' | ./$(BIN) -c '7%3.5' 2>&1)" '1' "and 7 % 3.5 is 1 for the same reason, not the 0 a true remainder gives"; \
	assert_out "$$(printf '%s' '1' | ./$(BIN) -c '10%2.5' 2>&1)" '0' "and a case where truncating and taking a true remainder happen to agree"; \
	assert_out "$$(printf '%s' '1' | ./$(BIN) -c '-5%3' 2>&1)" '-2' "and a negative dividend keeps its sign in the remainder"; \
	assert_out "$$(printf '%s' '1' | ./$(BIN) -c '5%-3' 2>&1)" '2' "and a negative divisor does not move it to the other side"; \
	assert_has "$$(printf '%s' '1' | ./$(BIN) '1%0' 2>&1)" 'number (1) and number (0) cannot be divided (remainder) because the divisor is zero' "a remainder by zero names both sides, as jq does"; \
	assert_has "$$(printf '%s' '1' | ./$(BIN) '1%0.3' 2>&1)" 'number (1) and number (0.3) cannot be divided (remainder) because the divisor is zero' "and a divisor that truncates to zero is refused too, as in jq"; \
	assert_has "$$(printf '%s' '1' | ./$(BIN) '1%0.5' 2>&1)" 'number (1) and number (0.5) cannot be divided (remainder) because the divisor is zero' "and 1 % 0.5 is refused, since 0.5 truncates to a zero divisor"; \
	assert_has "$$(printf '%s' '1' | ./$(BIN) '0.1%0.05' 2>&1)" 'number (0.1) and number (0.05) cannot be divided (remainder) because the divisor is zero' "and on both sides at once"; \
	assert_has "$$(printf '%s' '1' | ./$(BIN) '1/0' 2>&1)" 'number (1) and number (0) cannot be divided because the divisor is zero' "and so does a division by zero"; \
	assert_has "$$(printf '%s' '1' | ./$(BIN) '"a"+1' 2>&1)" 'string ("a") and number (1) cannot be added' "addition names both sides too"; \
	assert_has "$$(printf '%s' '1' | ./$(BIN) '1-"a"' 2>&1)" 'number (1) and string ("a") cannot be subtracted' "and subtraction"; \
	assert_has "$$(printf '%s' '1' | ./$(BIN) 'null-1' 2>&1)" 'null (null) and number (1) cannot be subtracted' "and jq refuses null for subtraction, as oojq does"; \
	assert_has "$$(printf '%s' '1' | ./$(BIN) '"a"/1' 2>&1)" 'string ("a") and number (1) cannot be divided' "and division"; \
	assert_has "$$(printf '%s' '1' | ./$(BIN) '["a",1,"b"]|add' 2>&1)" 'string ("a") and number (1) cannot be added' "a refusal inside add is the operator's own"; \
	assert_has "$$(printf '%s' '1' | ./$(BIN) '1|add' 2>&1)" 'Cannot iterate over number (1)' "and add refuses a non-iterable the way jq does"; \
	assert_out "$$(printf '%s' '[1,2,3]' | ./$(BIN) -c '.[]|[.]' 2>&1 | tr '\n' '|')" '[1]|[2]|[3]|' "a collect answers one array per value, not one for the stream"; \
	assert_out "$$(printf '%s' '[1,2,3]' | ./$(BIN) -c '.[]|[.,.]' 2>&1 | tr '\n' '|')" '[1,1]|[2,2]|[3,3]|' "and gathers each value's own answers"; \
	assert_out "$$(printf '%s' '[1,2,3]' | ./$(BIN) -c '.[]|select(.>1)|[.]' 2>&1 | tr '\n' '|')" '[2]|[3]|' "and a select in front does not merge them"; \
	assert_bytes "$$(printf '%s' '[1,2,3]' | ./$(BIN) -c 'empty|[.]' 2>/dev/null | wc -c)" '0' "a collect with nothing reaching it still answers nothing"; \
	assert_out "$$(printf '%s' '1' | ./$(BIN) -c '[empty]' 2>&1)" '[]' "and one that reached it collects to an empty array"; \
	assert_out "$$(printf '%s' '[1,2,3]' | ./$(BIN) -c '[.]' 2>&1)" '[[1,2,3]]' "and one value reaching it collects to one array"; \
	assert_out "$$(printf '%s' '[1,2,3]' | ./$(BIN) -c '1|[.]' 2>&1)" '[1]' "and a constant is a value like any other"; \
	assert_out "$$(printf '%s' '[1,2]' | ./$(BIN) -c '.[]|[]' 2>&1 | tr '\n' '|')" '[]|[]|' "and the empty collect answers once per value"; \
	assert_out "$$(jc '.meta|[.]')" '[{"stars":42,"active":true,"ratio":-3}]|' "and an object collects whole"; \
	assert_has "$$(printf '%s' '1' | ./$(BIN) '1|min' 2>&1)" 'number (1) and number (1) cannot be iterated over' "and min refuses it the way jq does"; \
	assert_out "$$(jc 'del(.meta)|has("meta")')" 'false|' "del removes the key it names"; \
	assert_out "$$(jc 'del(.missing)|type')" '"object"|' "and a key that is not there is a no-op"; \
	assert_out "$$(jc 'del(.meta.ratio)|.meta|keys|length')" '2|' "and a nested key goes, leaving its parent"; \
	assert_out "$$(printf '%s' '{"a":{"x":[1,2]},"b":[9,9]}' | ./$(BIN) -c 'del(.a.x[0])|.b|length' 2>&1)" '2' "and only the member the path named is cut, not every one"; \
	assert_out "$$(printf '%s' '{"a":{"x":[1,2]},"b":{"x":[9]}}' | ./$(BIN) -c 'del(.a.x[0])|.b.x|length' 2>&1)" '1' "including a sibling with the same shape"; \
	assert_out "$$(printf '%s' '{"t":["a","b","c"]}' | ./$(BIN) -c '[.t[]|del(.)]' 2>&1)" '[null,null,null]' "del is per value, as a filter is"; \
	assert_out "$$(printf '%s' '{"t":["a","b"]}' | ./$(BIN) -c 'del(.t[0])|.t|length' 2>&1)" '1' "and removes an array position"; \
	assert_out "$$(printf '%s' '{"a":1}' | ./$(BIN) -c 'del(.)' 2>&1)" 'null' "and del(.) is null, as jq reads it"; \
	assert_out "$$(jc 'path(.limits.rps)')" '["limits","rps"]|' "path names the way to a value"; \
	assert_out "$$(jc 'path(.tags[0])')" '["tags",0]|' "with a number for a position"; \
	assert_out "$$(jc 'path(.)')" '[]|' "and the empty path for the value in hand"; \
	assert_out "$$(jc '[path(.a,.b)]')" '[["a"],["b"]]|' "and one array per comma-separated path"; \
	assert_out "$$(printf '%s' '{"a":1}' | ./$(BIN) -c 'path(.x)' 2>&1)" '["x"]' "a path that names nothing is still a path"; \
	assert_has "$$(printf '%s' '{"a":1}' | ./$(BIN) 'del(.a[])' 2>&1)" 'is not one' "and a path that is more than a path is refused by name"; \
	assert_has "$$(printf '%s' '{"a":1}' | ./$(BIN) 'del(.a|.b)' 2>&1)" 'is not one' "including one with a pipe in it"; \
	assert_has "$$(printf '%s' '{"a":1}' | ./$(BIN) 'path(..)' 2>&1)" 'is not one' "and recursion"; \
	assert_has "$$(printf '%s' '1' | ./$(BIN) '1|any' 2>&1)" 'Cannot iterate over number (1)' "and so does any, in the words jq uses"; \
	assert_out "$$(printf '%s' 'null' | ./$(BIN) -c '(1,2,3) + (100,200)' 2>&1 | tr '\n' '|')" '101|102|103|201|202|203|' "both sides of an operator pair up right side first, as jq orders them"; \
	assert_out "$$(printf '%s' 'null' | ./$(BIN) -c '(1,2,3) - (100,200)' 2>&1 | tr '\n' '|')" '-99|-98|-97|-199|-198|-197|' "and the same order for subtraction"; \
	assert_out "$$(printf '%s' 'null' | ./$(BIN) -c '(100,200) + (1,2,3)' 2>&1 | tr '\n' '|')" '101|201|102|202|103|203|' "and it is not simply the order written"; \
	printf '%s' '{"a":[10,20,30],"b":{"z":1,"a":2},"items":[{"id":1,"k":"a"},{"id":2,"k":"b"}]}' > $(TMPDOC); \
	assert_out "$$(t '[1,2]|keys')" '[0,1]@' "keys on an array is numbers, not text"; \
	assert_out "$$(t '.a|keys')" '[0,1,2]@' "and they are the positions, in order"; \
	assert_out "$$(t '.b|keys')" '["a","z"]@' "while an object is still its own names"; \
	assert_out "$$(t '[.a|keys]|add')" '[0,1,2]@' "so add over them is a number and not a join"; \
	assert_out "$$(t '18446744073709551615')" '18446744073709551615@' "an integer wider than 64 bits is kept whole"; \
	assert_out "$$(t '18446744073709551616')" '18446744073709551616@' "and so is the next one up"; \
	assert_out "$$(t '0*-1')" '-0@' "a product of a zero and a negative is a negative zero"; \
	assert_out "$$(t '(0*-1)|tostring')" '"-0"@' "and it says so when spelled"; \
	assert_out "$$(t '(-0.4)|round')" '-0@' "and rounding down to nothing keeps the sign"; \
	assert_out "$$(t '(-0.1)|ceil')" '-0@' "and so does a ceiling that lands on it"; \
	assert_out "$$(t '(0*-1)==0')" 'true@' "a negative zero still equals zero"; \
	assert_out "$$(t '(0*-1)<0')" 'false@' "and is not less than it"; \
	assert_out "$$(t '(0*-1)-0')" '-0@' "and subtracting a zero keeps it a negative zero"; \
	assert_out "$$(t '0-(0*-1)')" '0@' "while the other way round is a positive zero"; \
	assert_out "$$(t '.items[]|.id * 2')" '2@4@' "an operator after an iterate pairs per value, not across them"; \
	assert_out "$$(t '.items[]|.id, .k')" '1@"a"@2@"b"@' "a comma after an iterate interleaves, one value at a time"; \
	assert_out "$$(t '[.items[]|.id * 2]')" '[2,4]@' "and a collect of one gathers the two, not the four"; \
	assert_out "$$(t '.items[]|if .id==1 then 1 else 2 end')" '1@2@' "a conditional after an iterate is asked per value"; \
	assert_out "$$(t '(.items[]|.id) * 2')" '2@4@' "and a widened left side still pairs right side first"; \
	assert_out "$$(t '(.items[0],.b)|.z?')" 'null@1@' "a question mark keeps the values that can take the step"; \
	assert_out "$$(t '(.items[0],.b)|.id?')" '1@null@' "and only the ones that cannot are left out"; \
	assert_out "$$(t '[(.items[]|tojson|fromjson)]|length')" '2@' "fromjson keeps the arena its collect is building in"; \
	assert_out "$$(d '{"a":1,"a":2}' '.')" '{"a":2}@' "a name written twice keeps the value it was last given"; \
	assert_out "$$(d '{"a":1,"a":2}' 'keys')" '["a"]@' "and the object holds that name once"; \
	assert_out "$$(d '{"a":1,"a":2}' 'length')" '1@' "so its length counts the name once"; \
	assert_out "$$(d '{"a":1,"a":2}' 'to_entries')" '[{"key":"a","value":2}]@' "and to_entries reads one member rather than two"; \
	assert_out "$$(d '{"b":1,"a":2,"b":3}' '.')" '{"b":3,"a":2}@' "a name written again keeps the position it was first given"; \
	assert_out "$$(d '{"a":1,"a":2}' 'tojson')" '"{\"a\":2}"@' "and the object spells itself with one name"; \
	assert_out "$$(d '[{"key":"a","value":1},{"key":"a","value":2},{"key":"b","value":3}]' 'from_entries')" '{"a":2,"b":3}@' "from_entries collapses a name it is handed twice"; \
	assert_out "$$(d '[{"key":"a","value":1},{"key":"a","value":2},{"key":"b","value":3}]' 'from_entries|length')" '2@' "so the object it rebuilds holds two names rather than three"; \
	assert_out "$$(d '[{"key":"a","value":1},{"key":"a","value":2},{"key":"b","value":3}]' 'from_entries|to_entries')" '[{"key":"a","value":2},{"key":"b","value":3}]@' "and reading that object back gives the last value under the first name"; \
	assert_out "$$(d 'null' '{}')" '{}@' "an object with no entries is still an object"; \
	assert_out "$$(d 'null' '{} | length')" '0@' "and it holds no members"; \
	assert_out "$$(d 'null' '{a: 1}')" '{"a":1}@' "a bare name is a key and not a call"; \
	assert_out "$$(d 'null' '{length: 1}')" '{"length":1}@' "so a builtin name here is only a name"; \
	assert_out "$$(d 'null' '{"a": 1, "b": 2}')" '{"a":1,"b":2}@' "two written entries build two members"; \
	assert_out "$$(d 'null' '{"a":1,}')" '{"a":1}@' "a trailing comma adds no member"; \
	assert_out "$$(d 'null' '{a:1,a:2}')" '{"a":2}@' "a name written twice keeps its last value"; \
	assert_out "$$(d 'null' '{a: 1} | keys')" '["a"]@' "and the built object reads back"; \
	assert_out "$$(d 'null' '{a: 1, b: 2} | paths')" '["a"]@["b"]@' "and every member has a path"; \
	assert_out "$$(d 'null' '{a: 1} | . + {b: 2}')" '{"a":1,"b":2}@' "and it adds like any other object"; \
	assert_out "$$(d '{"a":7}' '{"a"}')" '{"a":7}@' "a key written alone reads that name"; \
	assert_out "$$(d '{"a":1,"b":2}' '{a, b}')" '{"a":1,"b":2}@' "and several of them gather into one object"; \
	assert_out "$$(d '{"k":"x","v":9}' '{(.k): .v}')" '{"x":9}@' "a key in brackets is answered rather than used as written"; \
	assert_out "$$(d 'null' '{("aAb"): 1} == {"aAb": 1}')" 'true@' "and an escaped key is the same key"; \
	assert_out "$$(d 'null' '{a: (1,2)}')" '{"a":1}@{"a":2}@' "a value written as a generator builds one object per answer"; \
	assert_out "$$(d 'null' '{a:(1,2), b:(3,4)}')" '{"a":1,"b":3}@{"a":1,"b":4}@{"a":2,"b":3}@{"a":2,"b":4}@' "two generators multiply, the first written varying slowest"; \
	assert_bytes "$$(d 'null' '{a:empty, b:1}' | wc -c | tr -d ' ')" 0 "an entry that answered nothing leaves no object at all"; \
	assert_bytes "$$(d 'null' '{a:1, b:empty}' | wc -c | tr -d ' ')" 0 "and it does not matter which entry it was"; \
	assert_out "$$(d 'null' '1,2 | {a: 1}')" '{"a":1}@{"a":1}@' "an object is built for each value that reached it"; \
	assert_out "$$(d '[1,2]' '.[] | {a: .}')" '{"a":1}@{"a":2}@' "and each value of an iterate gets its own"; \
	assert_out "$$(d 'null' '1,2 | getpath([])')" '1@2@' "a call whose argument is a filter splits a stream per value"; \
	assert_has "$$(d 'null' '{1: 2}')" 'an object key must be' "a bare number cannot be a key"; \
	assert_has "$$(d 'null' '{.k: .v}')" 'an object key must be' "and a bare field cannot be a key either"; \
	assert_has "$$(d 'null' '{("a")}')" 'a shorthand key must be' "and a shorthand key cannot be in brackets"; \
	assert_out "$$(d '{"a":1,"b":2,"c":3}' 'with_entries(select(.value > 1))')" '{"b":2,"c":3}@' "with_entries keeps only the entries its body keeps"; \
	assert_out "$$(d '{"a":1,"b":2,"c":3}' 'with_entries({key: .key, value: .value})')" '{"a":1,"b":2,"c":3}@' "and a body that rebuilds an entry changes nothing"; \
	assert_out "$$(d '{"a":1,"b":2,"c":3}' 'with_entries(select(.key == "b") | {key: .key, value: .value})')" '{"b":2}@' "so the key a body picks is the key that survives"; \
	assert_out "$$(d '{"a":1,"b":2,"c":3}' 'with_entries(select(.value > 1)) | length')" '2@' "and the result is an object, not an array"; \
	assert_out "$$(d '{"limits":{"rps":500,"burst":750}}' '.limits | with_entries(select(.value > 600) | {key: .key, value: .value})')" '{"burst":750}@' "and it reads a nested object like any other"; \
	assert_out "$$(d '{"a":1,"b":2}' 'setpath(["a"];9)')" '{"a":9,"b":2}@' "setpath replaces a member where it stands"; \
	assert_out "$$(d '{"a":1,"b":2}' 'setpath(["x"];1)')" '{"a":1,"b":2,"x":1}@' "and appends a member that was not there"; \
	assert_out "$$(d '{"a":1,"b":2}' 'setpath([];5)')" '5@' "an empty path is the value itself"; \
	assert_out "$$(d '{"b":2}' 'setpath(["a","b"];1)')" '{"b":2,"a":{"b":1}}@' "a path through a member that is not there grows the object for it"; \
	assert_out "$$(d '{"a":1,"b":2}' 'setpath(["x","y"];1)')" '{"a":1,"b":2,"x":{"y":1}}@' "and keeps the members already written in their order"; \
	assert_out "$$(d 'null' 'setpath(["a",0];1)')" '{"a":[1]}@' "a null becomes an object for a name and an array for a position"; \
	assert_out "$$(d 'null' 'setpath([0];1)')" '[1]@' "so a position on a null grows an array"; \
	assert_out "$$(d 'null' 'setpath([0,1];1)')" '[[null,1]]@' "and the slot before it is the null it was"; \
	assert_out "$$(d 'null' 'setpath([1];1)')" '[null,1]@' "an array being created is as long as the position names"; \
	assert_out "$$(d 'null' 'setpath([2];1)')" '[null,null,1]@' "and every slot before the position is a null"; \
	assert_out "$$(d 'null' 'setpath([1,0];1)')" '[null,[1]]@' "so a two step path keeps the slot the first step named"; \
	assert_out "$$(d 'null' 'setpath([3,2,1];1)')" '[null,null,null,[null,null,[null,1]]]@' "and so does a path four deep"; \
	assert_out "$$(d 'null' 'setpath([0,"a"];1)')" '[{"a":1}]@' "a name still builds an object, not a padded array"; \
	assert_out "$$(d '[5]' 'setpath([2,0];1)')" '[5,null,[1]]@' "padding starts past the members already there"; \
	assert_out "$$(d '{}' 'setpath(["a",1];1)')" '{"a":[null,1]}@' "and past a member that had to be built first"; \
	assert_out "$$(d 'null' 'setpath([1.5];1)')" '[null,1]@' "a fractional position is read as the whole number in front of the dot"; \
	assert_out "$$(d 'null' 'setpath([-0.5];1)')" '[1]@' "and a negative fraction is the whole number it truncates to"; \
	assert_out "$$(d '[9]' 'setpath([1.5];1)')" '[9,1]@' "so it is a position and not a no-op"; \
	assert_out "$$(d '[1,2]' 'setpath([0];9)')" '[9,2]@' "a position inside an array is replaced"; \
	assert_out "$$(d '[1,2]' 'setpath([-1];9)')" '[1,9]@' "a negative position counts back from the end"; \
	assert_out "$$(d '[1,2]' 'setpath([3];1)')" '[1,2,null,1]@' "and a position past the end grows the array with nulls"; \
	assert_out "$$(d '[[1,2],[3]]' 'setpath([1,0];9)')" '[[1,2],[9]]@' "a path through a position walks into that child"; \
	assert_out "$$(d '{"a":1,"b":2}' 'setpath(["a"]; 1, 2)')" '{"a":1,"b":2}@{"a":2,"b":2}@' "a value written as a generator gives one answer each"; \
	assert_bytes "$$(d '{"a":1,"b":2}' 'setpath(["a"];empty)' | wc -c | tr -d ' ')" 0 "a value that answered nothing leaves no answer at all"; \
	assert_has "$$(d '[1,2]' 'setpath(["a"];1)')" 'Cannot index array with string "a"' "a name into an array is refused as jq refuses it"; \
	assert_has "$$(d '1' 'setpath(["a"];1)')" 'Cannot index number with string "a"' "and a number is refused the same way"; \
	assert_has "$$(d '{"a":1}' 'setpath([0];1)')" 'Cannot index object with number' "a position into an object names the kind, not the digits"; \
	assert_has "$$(d '{"a":1}' 'setpath([true];1)')" 'Cannot index object with boolean' "and so does any other kind of key"; \
	assert_has "$$(d '[1,2]' 'setpath([-3];9)')" 'Out of bounds negative array index' "a position before the start of the array is refused by name"; \
	assert_has "$$(d '{"a":1}' 'setpath("x";1)')" 'Path must be specified as an array' "a path that is not an array is refused as jq refuses it"; \
	assert_has "$$(d '{"a":1}' 'setpath([null];1)')" 'Cannot index object with null' "and a null key is named the same way"; \
	assert_has "$$(d 'null' 'setpath([{}];1)')" 'Array/string slice indices must be integers' "an object is never a position, wherever it was tried"; \
	assert_has "$$(d '[1,2]' 'setpath([{}];1)')" 'Array/string slice indices must be integers' "and the same sentence is used on an array"; \
	assert_has "$$(d '{"a":1}' 'setpath([{}];1)')" 'Cannot index object with object' "while an object named on an object takes the ordinary one"; \
	assert_has "$$(d '{"a":1}' 'setpath(["a"])')" 'setpath/1 is not defined' "and the wrong number of arguments names the arity"; \
	assert_out "$$(d '{"a":1,"b":2}' '.a = 7')" '{"a":7,"b":2}@' "an assignment replaces a member"; \
	assert_out "$$(d '{"a":1,"b":2}' '.zz = 7')" '{"a":1,"b":2,"zz":7}@' "and appends one that was not there"; \
	assert_out "$$(d '{"a":1,"b":2}' '.a = (1,2)')" '{"a":1,"b":2}@{"a":2,"b":2}@' "a generator on the right gives one object each"; \
	assert_out "$$(d '{"a":1,"b":2}' '.a = .b')" '{"a":2,"b":2}@' "and the right side is read as a filter"; \
	assert_out "$$(d 'null' '.a = 7')" '{"a":7}@' "an assignment into a null grows the object for it"; \
	assert_out "$$(d 'null' '.a.b.c = 1')" '{"a":{"b":{"c":1}}}@' "and builds every step of the way down"; \
	assert_out "$$(d 'null' '.a.b[0] = 1')" '{"a":{"b":[1]}}@' "so a name and then a position builds both"; \
	assert_out "$$(d '{"a":{"b":[1,2]}}' '.a.b[0] = 1')" '{"a":{"b":[1,2]}}@' "and reads a path already in the value"; \
	assert_out "$$(d '[10,20,30]' '.[-1] = 9')" '[10,20,9]@' "a position counts back from the end"; \
	assert_out "$$(d '[10,20,30]' '.[9] = 9')" '[10,20,30,null,null,null,null,null,null,9]@' "and one past the end pads with nulls"; \
	assert_bytes "$$(d '{"a":1,"b":2}' '.a = empty' | wc -c | tr -d ' ')" 0 "an assignment whose right side answers nothing answers nothing"; \
	assert_out "$$(d '{"a":1,"b":2}' '.a |= .+10')" '{"a":11,"b":2}@' "an update reads the value it is updating"; \
	assert_out "$$(d '{"a":1,"b":2}' '.a |= empty')" '{"b":2}@' "and an update that answers nothing cuts the key"; \
	assert_out "$$(d '{"a":1,"b":2}' '.zz |= empty')" '{"a":1,"b":2}@' "while a key that was never there is a no-op"; \
	assert_out "$$(d '{"a":1,"b":2}' '.a |= (1,2)')" '{"a":1,"b":2}@' "and an update that answers twice keeps the first"; \
	assert_out "$$(d '[10,20,30]' '.[0] |= empty')" '[20,30]@' "an update that answers nothing cuts the slot"; \
	assert_out "$$(d 'null' '.a |= empty')" 'null@' "and on a null there was nothing to cut"; \
	assert_out "$$(d '{"a":1}' '(.a) |= .+1')" '{"a":2}@' "a path in parentheses is still a path"; \
	assert_out "$$(d '{"a":1,"b":2}' '.a += 7')" '{"a":8,"b":2}@' "an arithmetic update adds"; \
	assert_out "$$(d '{"a":1,"b":2}' '.a += (1,2)')" '{"a":2,"b":2}@{"a":3,"b":2}@' "and keeps every answer rather than the first"; \
	assert_out "$$(d '{"a":1,"b":2}' '.a -= 1')" '{"a":0,"b":2}@' "subtracting is the same shape"; \
	assert_out "$$(d '{"a":1,"b":2}' '.a *= 2')" '{"a":2,"b":2}@' "and so is multiplying"; \
	assert_out "$$(d '{"a":1,"b":2}' '.a /= 4')" '{"a":0.25,"b":2}@' "and dividing, which keeps the fraction"; \
	assert_out "$$(d '{"a":1,"b":2}' '.a %= 3')" '{"a":1,"b":2}@' "and the remainder"; \
	assert_out "$$(d '[10,20,30]' '.[-1] *= 2')" '[10,20,60]@' "a position is updated like any other"; \
	assert_out "$$(d 'null' '.a += 7')" '{"a":7}@' "and a null reads as null for the arithmetic"; \
	assert_bytes "$$(d '{"a":1,"b":2}' '.a += empty' | wc -c | tr -d ' ')" 0 "an arithmetic update that answers nothing answers nothing"; \
	assert_out "$$(d '{"a":1}' '.a-=1')" '{"a":0}@' "an operator written with no space either side is still one"; \
	assert_out "$$(d '{"a":1}' '.a + 1')" '2@' "and a plus that is not an update is still a plus"; \
	assert_has "$$(d '{"a":1,"b":2}' '.a.b.c = 1')" 'Cannot index number with string "b"' "an assignment through a scalar is refused as jq refuses it"; \
	assert_has "$$(d '{"a":1,"b":2}' '.a[0] = 5')" 'Cannot index number with number' "and a position through one is too"; \
	assert_has "$$(d '[10,20,30]' '.a = 7')" 'Cannot index array with string "a"' "and a name into an array keeps its own sentence"; \
	assert_has "$$(d '{"a":1,"b":2}' '.a = .b = 1')" 'unexpected "="' "two assignments in a row is refused, as in jq"; \
	assert_has "$$(d '{"a":1,"b":2}' '1 = 1')" 'the left of an update has to be a path' "and so is a left side that is not one"; \
	assert_has "$$(d '{"a":1,"b":2}' '(.a,.b) = 7')" 'is not one' "a path naming two members is refused by name"; \
	assert_has "$$(d '{"a":1,"b":2}' '.a //= 9')" 'the //= operator is not supported' "and //= is refused by name rather than answered wrongly"; \
	assert_has "$$(d '{"a":1}' '.a.b')" 'Cannot index number with string "b"' "a name taken through a number is refused as jq refuses it"; \
	assert_has "$$(d '1' '.["a"]')" 'Cannot index number with string "a"' "and so is a quoted name through one"; \
	assert_has "$$(d '1' '.[0]')" 'Cannot index number with number' "and a position through one names the kind, not the digits"; \
	assert_has "$$(d '"s"' '.a')" 'Cannot index string with string "a"' "a string is a scalar like any other here"; \
	assert_has "$$(d 'true' '.a')" 'Cannot index boolean with string "a"' "and a boolean is refused as a boolean, not a bool"; \
	assert_has "$$(d '1' '.[]')" 'Cannot iterate over number (1)' "an iterate over a number names the value it was given"; \
	assert_has "$$(d '"s"' '.[]')" 'Cannot iterate over string ("s")' "and a string is written in quotes"; \
	assert_has "$$(d 'true' '.[]')" 'Cannot iterate over boolean (true)' "and a boolean as itself"; \
	assert_has "$$(d 'null' '.[]')" 'Cannot iterate over null (null)' "and a null is refused here, though indexing it is still null"; \
	assert_out "$$(d 'null' '.a')" 'null@' "so a missing member is a null and not an error"; \
	assert_out "$$(d 'null' '.[0]')" 'null@' "and so is a position"; \
	assert_out "$$(d '{"a":1}' '.[]')" '1@' "while an object iterates over its members"; \
	assert_bytes "$$(d '1' '.[]?' | wc -c | tr -d ' ')" 0 "a question mark swallows the refusal of an iterate"; \
	assert_bytes "$$(d 'null' '.[]?' | wc -c | tr -d ' ')" 0 "and it swallows a null one as well"; \
	assert_has "$$(d 'null' 'with_entries')" 'needs a filter argument' "a bare with_entries says it wants an argument"; \
	assert_has "$$(d 'null' 'limit')" 'needs a filter argument' "and so does a bare limit, which exists too"; \
	assert_has "$$(python3 -c "print('['*600 + ']'*600)" | ./$(BIN) . 2>&1)" 'exceeds maximum nesting depth limit' "payload exceeding nesting depth limit is refused"; \
	assert_has "$$(echo 'null' | ./$(BIN) -c "$$(python3 -c "print('('*300 + '.' + ')'*300)")" 2>&1)" 'exceeds maximum nesting depth limit' "filter exceeding nesting depth limit is refused"; \
	assert_has "$$(echo '1' | ./$(BIN) -c 'recurse(.)' 2>&1)" 'recurse exceeded maximum depth limit' "infinite recurse generator is stopped at depth limit"; \
	assert_has "$$(echo '1' | ./$(BIN) -c '(.,.)|(.,.)|(.,.)|(.,.)|(.,.)|(.,.)|(.,.)|(.,.)|(.,.)|(.,.)|(.,.)|(.,.)|(.,.)|(.,.)|(.,.)|(.,.)|(.,.)' 2>&1)" 'stream size limit exceeded' "combinatorial stream explosion is stopped at size ceiling"; \
	assert_has "$$(echo '{"jsonrpc":"2.0","method":"initialize","id":1}' | head -c 10 | ./$(BIN) --mcp 2>&1)" 'truncated frame at end of input' "mcp loop handles truncated input safely"; \
	assert_has "$$(printf 'Content-Length: 20000000\r\n\r\n' | ./$(BIN) --mcp 2>&1)" 'frame size exceeds limit' "mcp loop enforces frame size ceiling"; \
	assert_has "$$(python3 -c "print('x'*100000)" | ./$(BIN) --mcp 2>&1 | head -n 3)" 'frame buffer ceiling exceeded' "mcp loop enforces frame buffer ceiling"; \
	assert_has "$$(echo 1 | ./$(BIN) -c "$$(python3 -c "print('+'.join(['1']*500))")" 2>&1)" 'exceeds maximum nesting depth limit' "filter with deeply chained additions is refused cleanly"; \
	assert_out "$$(printf '%s\n' '{"a": "\u0022"}' | ./$(BIN) -c . 2>&1)" '{"a":"\""}' "u0022 in string decodes to quote"; \
	assert_out "$$(printf '%s\n' '{"a": "\u005c"}' | ./$(BIN) -c . 2>&1)" '{"a":"\\"}' "u005c in string decodes to backslash"; \
	assert_has "$$(printf 'Content-Length: 100\r\n\r\n{"short":' | ./$(BIN) --mcp 2>&1)" '"code":-32700' "mcp loop emits json-rpc error frame on framed truncation";  echo $$pass $$fail >> $(CNT);
	@rm -f $(TMPDOC) $(DUPDOC);
	@awk '{p+=$$1; f+=$$2} END { if (f>0) { print ""; print "FAIL: " f " of " (p+f) " tests failed"; exit 1 } else { print ""; print "PASS: " (p+f) "/" (p+f) " behaviour tests hold" } }' $(CNT);
	@rm -f $(CNT)

verify: line-cap file-law academy density suggest-audit dead-tests dup-names test check

# --- Parity against the real jq ---------------------------------------------
#
# The point of oojq is to be a better jq, so the claim has to be measured rather
# than asserted. Every case below is run through both binaries in both output
# modes and compared byte for byte. This target is informational: a low number
# is the honest state of the implementation, not a build failure, so it is kept
# out of `verify` and skips cleanly when jq is absent.
#
# A case where both binaries agree counts as a pass even when neither printed
# anything, so an exit status of 1, which here means the filter selected
# nothing, is not mistaken for a refusal. A status of 2 or more is a refusal and
# is counted as unsupported, and it is also printed, once, with the reason the
# binary gave. A count alone cannot be checked: the refusal list in the README
# is a claim about which boundaries were drawn on purpose, and a number that
# only ever appears as a total is a number nobody can hold to. The reason is
# read from stdout rather than stderr, because oojq writes its errors to stdout
# where jq writes to stderr; that divergence is recorded in the README and
# pinned by assertions, and reading stderr here would print a blank line for
# every case. A case where both answer and disagree is reported on its own line
# rather than folded into either total, because silently
# dropping it is how a number stops meaning anything.

PARITY_DOC = /tmp/oojq_parity_doc.json
PARITY_CASES = /tmp/oojq_parity_cases.txt
PARITY_REJECTS = /tmp/oojq_parity_rejects.txt
SWEEP_REJECTS = /tmp/oojq_sweep_rejects.txt

parity: build
	@if ! command -v jq >/dev/null 2>&1; then \
	  echo "SKIP: jq is not installed, so there is nothing to compare against"; exit 0; \
	fi; \
	: > $(PARITY_REJECTS); \
	printf '%s\n' '{"name":"api","port":8080,"ratio":1.5,"neg":-7,"zero":0,"ok":true,"off":false,"nothing":null,"tags":["prod","edge"],"limits":{"rps":500,"burst":750},"items":[{"id":1,"k":"a"},{"id":2,"k":"b"},{"id":3,"k":"a"}],"txt":"Hello World","esc":"a\"b\\c\nd\te","utf":"h\u00e9llo","nest":[[1,2],[3],[]]}' > $(PARITY_DOC); \
	printf '%s\n' '.' '.name' '.missing' '.ratio' '.neg' '.nothing' '.ok' '.tags' '.tags[]' \
	 'limit(2; 1,2,3)' 'limit(0; 1,2,3)' 'limit(5; 1,2,3)' '[limit(3; .items[])]' '[limit(2; empty)]' 'limit(1; .items[])' \
	 '[1,2,3][0:5]' '[1,2,3][1:99]' '[][0:2]' '[1,2,3][2:5]' '[1,2,3][5:9]' \
	 '.limits' '.limits[]' '.items[]' '.items[].k' '.tags[0]' '.tags[-1]' '.tags[0:1]' \
	 '{}' '{a: 1}' '{a:1,a:2}' '{a: (1,2)}' '{a:(1,2), b:(3,4)}' '{a:empty}' '{"a"}' \
	 '{a: .name, b: .port}' '{("a"): 1}' '{a:1} | keys' '{a:1,b:2} | paths' \
	 '1,2 | {a: 1}' '[.items[]|{id: .id}]' '[.items[]|{id: .id, dbl: .id * 2}]' \
	 'with_entries(select(.value > 1))' 'with_entries({key: .key, value: .value})' \
	 '.limits | with_entries(select(.value > 600) | {key: .key, value: .value})' \
	 'setpath(["name"]; "x")' 'setpath(["zz"]; 1)' 'setpath([]; 5)' 'setpath(["name","zz"]; 1)' \
	 'setpath(["limits","rps"]; 1)' 'setpath([0]; 1)' 'setpath([0,1]; 1)' 'setpath([-1]; 1)' \
	 'setpath([1,0]; 1)' 'setpath([9]; 1)' 'setpath([0]; empty)' 'setpath(["name"]; 1, 2)' \
	 'setpath(["tags",0]; "x")' 'setpath(["a"]; 1)' 'setpath([0]; 1)' 'setpath([-9]; 1)' \
	 'setpath("x"; 1)' 'setpath(3; 1)' 'setpath(["a"])' 'setpath(["a"]; 1; 2)' \
	 '[.items[] | setpath(["k"]; .k)]' 'setpath(["name"]; .) | keys' \
	 '.name = "x"' '.missing = 1' '.name = (.port, 0)' '.name |= ascii_upcase' \
	 '.name |= empty' '.missing |= empty' '.name |= (.port, 0)' '.limits.rps += 1' \
	 '.limits.rps -= 1' '.limits.rps *= 2' '.limits.rps /= 4' '.limits.rps %= 3' \
	 '.items[0].id += 1' '.name = .port' '(.name) = "y"' '(.limits) = 1' \
	 '.limits.burst = .limits.rps' '[.items[] | .id += 1]' '.name += (.port, 0)' \
	 '.name |= . + "!"' '.nothing |= empty' '.items[-1].id *= 10' \
	 '0.1*0.2 > 0.02' '0.1+0.2 > 0.3' '3.3/1.1 < 3' '0.1*0.2 == 0.02' \
	 '0.1*0.2 < 0.021' '(0.1+0.2) == 0.3' '1.1*1.1 == 1.21' '0.5+0.25 == 0.75' \
	 '.items[0]' '.length' 'length' 'keys' '.limits|keys' 'type' '.ratio|type' 'has("name")' \
	 '5|length' '(-5)|length' '0|length' 'null|length' '3.5|length' '(-2.5)|length' \
	 '"abc"|length' '[1,2]|length' '.limits|length' '.ok|length' \
	 'null|not' 'false|not' 'true|not' '0|not' '2|not' '[]|not' '"x"|not' '.port|not' \
	 'empty | []' 'empty | [.]' 'empty | 1' '1 // [] | length' '(1,2) | [] | length' \
	 '1 // []' 'null // []' 'empty // []' '[empty]' '.items[] | select(.id==9) | [.]' \
	 '.tags[] | select(.=="prod") | [.]' '.items[] | [.]' '1 // error("never")' \
	 '.name|utf8bytelength' '.txt|utf8bytelength' '.esc|utf8bytelength' '.utf|utf8bytelength' \
	 '.ok|toboolean' '.port|toboolean' '.ratio|isfinite' '.ratio|isnan' '.ratio|isinfinite' \
	 '.port|isfinite' '.name|isnan' '.ok|isinfinite' '.ratio|toboolean' \
	 'has("zzz")' '.items|map(.id)' '.items|map(.k)' '.items|map(select(.id>1))' '.tags|length' \
	 '.items|length' '[range(3)]' '.ratio + 1' '.port * 2' '.port - 8' '.port / 2' '.port % 7' \
	 '.neg|abs' '.ratio|floor' '.ratio|ceil' '.tags|join("-")' '.tags|sort' '.tags|reverse' \
	 '.tags|unique' '.items|group_by(.k)' '.items|map(.id)|add' '.items|map(.id)|max' \
	 '[.items[]|.id]|add(.)' '[.items[]|.id]|add(.[])' '[.items[]|.k]|add(.)' \
	 '[.tags[]]|add(.)' '[.tags[]]|add(length)' 'add(.)' 'add(.a)' \
	 '[.items[]|.id]|add(.[0], .[1])' '[.items[]|.id]|add(empty)' \
	 '[.items[]|.id]|add(.[] | .*2)' '[[.tags]]|add(.)' '[.limits[]]|add(.)' \
	 '[.items[]|.id]|add(.;.)' '[.txt]|add(.)' '[.nothing]|add(.)' \
	 '.items|has(0)' '.items|has(2)' '.items|has(3)' '.items|has(-1)' '.items|has(0.5)' \
	 '.items|has(2.5)' '[]|has(0)' 'null|has(0)' 'null|has("a")' 'has(0)' \
	 '.limits|has("rps")' '.limits|has("zzz")' '[1,2,3]|join(",")' '[1,null,true]|join(",")' \
	 '[1.5,2.5]|join("|")' '.limits|join(",")' '{}|join(",")' '["a","b"]|join(null)' \
	 '[]|join(",")' '[null]|join(",")' '{"b":2,"a":1}|join(",")' '["x",1,true,null]|join("+")' \
	 '.items[0]|join(",")' \
	 'length("x")' 'tostring("x")' 'tonumber("x")' 'type("x")' 'keys("x")' \
	 'sort("x")' 'reverse("x")' 'unique("x")' 'floor("x")' 'tojson("x")' \
	 'true|contains(true)' 'false|contains(false)' 'true|contains(false)' \
	 'false|contains(true)' '[.tags[]]|first(.)' '[.tags[]]|last(.)' \
	 '1 as $$x | $$x' 'as $$x' '.a as $$x | .' \
	 '.a //= 9' '.b //= 9' '.d //= 9' '.e //= 9' '.a //= (empty)' \
	 '.a |= (. // 9)' '.d |= (. // 9)' '.e |= (. // 9)' '[.a,.b,.d]|map(. // 9)' \
	 '.items|map(.id)|min' '.tags|contains(["prod"])' '.txt|ascii_downcase' \
	 '.txt|startswith("Hello")' '.txt|endswith("World")' '.txt|test("World")' \
	 '.txt|ltrimstr("Hello ")' '.items|to_entries' '.items|from_entries' \
	 'if .port > 100 then "big" else "small" end' '.name // "fallback"' \
	 '.missing // "fallback"' '.tags[]?' '[.tags[]|select(.=="prod")]' '.tags|any(.=="x")' \
	 '.tags|all(.!="")' '[empty]' '.tags[]|tostring' '"12"|tonumber' '.items|map(.id)|first' \
	 '.items|map(.id)|last' '[paths]' '[..]' \
	 '[.items[].id]|sort' '[.items[].id]|unique' '[3,1,2,1]|sort' '[3,1,2,1]|unique' \
	 '[.limits[]|sort]' '["b","a"]|sort' '[null,1,"a",true,[1]]|sort' '[1,1.0]|unique' \
	 '.ratio == 1.5' '.port > 100' '.port >= 8080 and .ok' '.ok or .off' '.ok|not' \
	 '.items|length == 3' '[.tags[]|.]' '.esc' '.zero' '.off' '.items[1].k' '.items[-1].id' \
	 '.tags|.[0]' '.items|map(.k)|join("+")' '[.limits|to_entries[]|.key]' \
	 '.items|map(.k)|sort' '.txt|length' '.tags|map(length)' \
	 'keys_unsorted' '.limits|keys_unsorted' '.tags|keys_unsorted' 'values' '.nothing|values' \
	 '[.items[]|numbers]' '[.items[]|strings]' '[.items[]|booleans]' '[.items[]|nulls]' \
	 '[.items[]|arrays]' '[.items[]|objects]' '[.items[]|scalars]' '[.items[]|iterables]' \
	 '.nest|flatten' '.nest|flatten(1)' '.nest|flatten(0)' '[.nest[]|flatten]' \
	 'tojson' '.limits|tojson' '.nothing|tojson' '"[1,2]"|fromjson' '"{\"a\":1}"|fromjson' \
	 '"1970-01-01T00:00:00Z"|fromdateiso8601' '"2021-07-14T02:40:00Z"|fromdateiso8601' \
	 '.utf' '.utf|length' '.utf|explode' '[104,105]|implode' '.utf|index("l")' \
	 '.utf|rindex("l")' '.utf|index("z")' '.utf|tojson' '.txt|index("World")' \
	 '[.tags[]|.]|tojson' '.utf|ascii_downcase' '.esc|length' \
	 '.items|sort_by(.k)|map(.id)' '.items|sort_by(.id)|map(.id)' '.items|unique_by(.k)|map(.k)' \
	 '.items|min_by(.k).id' '.items|max_by(.k).id' '.items|min_by(.id).id' '.items|max_by(.id).id' \
	 '.items|group_by(.k)|length' '.items|sort_by(.k)|length' '.items|unique_by(.k)|length' \
	 '.tags|first(.[])' '.tags|last(.[])' '.tags|sort|first(.)' '.tags|first(empty)' \
	 '.tags|last(empty)' '[first(empty)]' '[last(empty)]' 'first(empty) // "d"' \
	 '[null]|first(.)' '[[]]|first(.)' '[1,2]|last(empty)' \
	 '.txt|split(" ")|length' '.txt|split("o")|.[]' '["a","b"]|split(",")' \
	 '.tags|sort|join("-")' '.tags|unique|join("-")' '.tags|reverse|first(.)' \
	 '.items|sort_by(.k)|map(.k)' '.items|group_by(.k)|map(length)' \
	 '.txt|test("[A-Z]")' '.txt|test("z")' \
	 '[2015,2,5,14,30,25]|strftime("%F %T")' '[2015,2,5,14,30,25]|strftime("%c")' \
	 '[2015,2,5]|strftime("%a %A %b %B %j %u %w %U %W %G %V %z %Z")' \
	 '0|strftime("%F %T")' '1425565825|strftime("%Y-%m-%d %H:%M:%S")' \
	 '1500000000|gmtime|strftime("%Y/%m/%d %H:%M:%S %j")' \
	 '[2015,2,5,25,70,70]|strftime("%F %T")' '[-1,0,1]|strftime("[%Y][%y][%C]")' \
	 '[2015,2,5]|strftime("%D%T%r%x%X")' '[2015,2,5]|strftime("%Q%%a%")' \
	 '[2016,0,1]|strftime("%G %V")' '[2017,0,1]|strftime("%G %V")' \
	 '[2015,2,5]|strftime("%Y","%m")' '"x"|strftime("%F")' \
	 '[2015,"x"]|strftime("%F")' '[2015,2,5]|strftime(1)' '[2015,2,5]|strftime' \
	 '[2015,2,5]|strftime("%F %s")' \
	 '"2015-03-05"|strptime("%Y-%m-%d")' '"2015-03-05T14:30:25Z"|strptime("%Y-%m-%dT%H:%M:%SZ")' '"2015-03-05T14:30:25+05:30"|strptime("%Y-%m-%dT%H:%M:%S%z")' \
	 '"2015-03-05"|strptime("%F")' '"2015-03-05 14:30:25"|strptime("%F %T")' '"2015-03-05T14:30:25Z"|strptime("%FT%TZ")' \
	 '"03/05/15"|strptime("%D")' '"03/05/15"|strptime("%x")' '"15-03-05"|strptime("%y-%m-%d")' \
	 '"68"|strptime("%y")' '"69"|strptime("%y")' '"20 15"|strptime("%C %y")' \
	 '"Mar 5 2015"|strptime("%b %d %Y")' '"December 5 2015"|strptime("%B %d %Y")' '"Thu, 05 Mar 2015 14:30:25 GMT"|strptime("%a, %d %b %Y %H:%M:%S %Z")' \
	 '"2015 064"|strptime("%Y %j")' '"2015 366"|strptime("%Y %j")' '"1900 366"|strptime("%Y %j")' \
	 '"2016 366"|strptime("%Y %j")' '"2015 064 9"|strptime("%Y %j %d")' '"2015 12 031"|strptime("%Y %m %j")' \
	 '"2015 7"|strptime("%Y %u")' '"2015 6"|strptime("%Y %w")' '"2015"|strptime("%Y")' \
	 '"Mar"|strptime("%b")' '"2015- 3- 5"|strptime("%Y-%m-%d")' '"2015-03-05T14:30:25Z"|strptime("%Y-%m-%dT%H:%M:%SZ")|mktime' \
	 '"2015-03-05T14:30:25Z"|strptime("%Y-%m-%dT%H:%M:%SZ")|strftime("%F %T %Z %z")' '1500000000|gmtime|strftime("%Y-%m-%d")|strptime("%Y-%m-%d")|mktime' '"2015-03-05T14:30:25Z"|strptime("%Y-%m-%dT%H:%M:%SZ")|mktime|todate' \
	 '"abcabc"|indices("b")' '"abcabc"|indices("bc")' '"aaaa"|indices("aa")' \
	 '"ababab"|indices("abab")' '"abcabc"|indices("z")' '[1,2,1,2]|indices(1)' \
	 '[1,2,1,2]|indices(2)' '[1,2,3]|indices(9)' '["ab","cd","ab"]|indices("ab")' \
	 '[{"a":1},{"a":1}]|indices({"a":1})' '[null,null]|indices(null)' 'null|indices("a")' \
	 '"héllo"|indices("l")' '"日本語"|indices("本")' '[]|indices(1)' \
	 '"abcabc"|indices("bc")|index("bc")' '"" |split("b")' '"" |split("")' \
	 '"a"|split("a")' '"abc"|split("d")' '"abc"|split("bc")' '"" |ltrimstr("a")' \
	 '"abc"|startswith("a")' '"abc"|endswith("c")' '"abc"|test("b")' '"abcabc"|index("b")' \
	 '"abcabc"|rindex("bc")' '[1,2,1,2]|rindex(1)' '[1,null]|index(null)' \
	 'null|index("a")' 'null|index(1)' 'null|index(1.5)' \
	 'null|index({})' 'null|rindex("a")' 'null|rindex(1)' \
	 'null|indices("a")' 'null|indices(1)' '[1,null]|index(null)' \
	 '[1,null]|rindex(null)' '[1,null]|indices(null)' '[1]|index(1)' \
	 '[]|index(1)' '[[1]]|index(1)' '[1,2,3]|add' \
	 '[]|add' '[1,2]|add' '{"a":1}|add' \
	 '[1,2,3]|map(.)|add' '[.items[]|length]' '[.tags[]|length]' \
	 '[.limits]|add' '.txt|indices("l")' '.name|indices("a")' \
	 '.missing // .name' '.nothing // .port' 'empty // .name' '.tags // .name' \
	 '.missing // empty' '1 // (2,3)' '1 // error("boom")' '.tags[0] // .name' \
	 '.missing.a // .name' '[.tags[]|select(.=="nope")] // "d"' '.tags[-1] // .name' \
	 'empty // .tags[]' '.name // .port' '.nothing // .tags[0]' '.off // .ok' \
	 '.limits|getpath(["rps"])' '.items|getpath([0,"k"])' '.tags|getpath([-1])' \
	 '.tags|getpath([9])' 'getpath([])' '.limits|getpath(["zzz"])' '.items|getpath([0.5])' \
	 '@json' '.|@json' 'tojson|@json' '.|@text' '.port|@text' '.tags|@text' '.ok|@text' \
	 '.nothing|@text' '.txt|@uri' '.utf|@uri' '@uri' '.txt|@html' '.esc|@html' '.|@html' \
	 '.utf|@text' '.esc|@text' '.|@uri' '.nothing|@html' '1|@html' '[1,2]|@uri' \
	 '.txt|@base64' '.utf|@base64' '.name|@base64' '.port|@base64' '.tags|@base64' \
	 '.|@base64' '.nothing|@base64' '""|@base64' '[104,105]|implode|@base64' \
	 '.txt|@base64|@base64d' '.utf|@base64|@base64d' '.esc|@base64|@base64d' \
	 '.tags|@base64|@base64d' '"aGVsbG8="|@base64d' '"YQ=="|@base64d' '"YWJj"|@base64d' \
	 '"ab"|@base64d' '"YQ==="|@base64d' '"aGVsbG8"|@base64d' '"AA=A"|@base64d' \
	 '""|@base64d' '"aGk="|@base64d' '"i+/v"|@base64d' '"a"|@base64d' '"!!!"|@base64d' \
	 '"a-b_"|@base64d' '"A==="|@base64d' '"a b"|@base64d' \
	 '[false,false]|any' '[true,false]|all' '[]|any' '[]|all' '[[]]|any' '[[]]|all' \
	 '[0,1]|any' '[0,1]|all' '[null]|all' '.tags|any' '.tags|all' '[.limits[]|any]' \
	 '[.items[]|all]' '[.limits[]|all]' \
	 '["a","b"]|@csv' '[1,"x"]|@csv' '[1,null,true,false]|@csv' '[]|@csv' \
	 '["a\"b","c,d"]|@csv' '["a\tb"]|@csv' '[1,2]|@tsv' '["a\tb"]|@tsv' \
	 '["a\\b"]|@tsv' '["a\nb"]|@tsv' '[]|@tsv' '[1,null,true]|@tsv' '["héllo"]|@csv' \
	 '.txt|@sh' '["a","b"]|@sh' '[]|@sh' '1.5|@sh' '.tags|@sh' 'null|@sh' '.nothing|@sh' \
	 '[[1,2]]|@csv' '1|@csv' '{"a":1}|@csv' '[[1,2]]|@sh' '[[1]]|@tsv' \
	 '0|sqrt' '4|sqrt' '9|sqrt' '16|sqrt' '100|sqrt' '1000000|sqrt' '0.25|sqrt' \
	 '2.25|sqrt' '0.0625|sqrt' '0.0001|sqrt' '0.0|sqrt' '4.0|sqrt' '1e2|sqrt' '-4|sqrt' \
	 '2|sqrt' '10|sqrt' '0.5|sqrt' '40|sqrt' '1.5|sqrt' 'null|sqrt' '"a"|sqrt' 'true|sqrt' \
	 '[1,2]|sqrt' '.port|sqrt' '.neg|sqrt' '.zero|sqrt' \
	 '(-3)+0' '(-3)-0' '0-(-3)' '(-3)*(-1)' '(-3)*2' '(-3)/1' '(-3)%2' \
	 '(-3)|abs' '(-3.5)|abs' '(-3)|fabs' '(-3.5)|fabs' '(0*-1)|fabs' '(-0)|fabs' \
 '(-3)|floor' '(-3.5)|floor' '(-3)|ceil' '(-3.5)|ceil' \
	 '(-3)|round' '(-3.5)|round' '(-0.5)|round' '(-1)|abs' '(-2.5)|floor' '(-2.5)|ceil' \
	 '(-3) < 0' '(-3) > 0' '(-3) == 0' '(-3) <= (-3)' '(-3) < (-2)' '(-3) > (-4)' '0 < (-3)' \
	 '.neg + 1' '.neg - 1' '.neg * 2' '.neg / 1' '.neg % 3' '.neg|abs' '.neg|floor' '.neg|ceil' \
	 '.neg|round' '.neg < 0' '.neg > 0' '.neg == (-7)' '.neg|tostring' '(-1.5)+(-1.5)' \
	 '(-1.5)*2' '3 - (-3)' '[-3,-2]|add' '[-3,-2]|max' '[-3,-2]|min' '[-3,-2]|sort' \
	 '[-3,-2]|reverse' '[-3,2]|add' '[-3,2]|max' '[-3,2]|sort' '(-4)|sqrt' '(-0.5)|sqrt' \
	 '[-7,-2]|group_by(.)' '[-7,-2]|unique' '[-7,-2]|sort' '[-3,-2]|group_by(.)' \
	 '[-3,-2]|unique_by(.)' '[-3,-2]|min_by(.)' '[-3,-2]|max_by(.)' '[-3,-2]|sort_by(.)' \
	 '.items|map(-.id)|add' '.items|map(.id-1)|max' '(.neg,.ratio)|add' \
	 '1.5*2' '2*1.5' '1.5*1.5' '2.5*2' '1.5*0' '(-1.5)*2' '0.5*0.5' '0*1.5' '2*0.5' \
	 '1000000*0.000001' '123456789*0.000000001' '2*"a"' '1.5*(-2)' '(-1.5)*(-2)' '1.5*1.5+0.1' \
	 '0.1*0.2' '1.23456789*1.23456789' '0.3*0.3' '1.1*1.1' '(-0.1)*0.2' \
	 '1+2.25' '2.25+0.1' '0.5+0.25' '1.05+0.5' '100.5+1.25' '0.1+0.05' '1.1+0.1' '3.75+1.5' \
	 '2.25-0.1' '100.5-0.25' '10.5+0.25' '2.5+0.5' '1.25+0.5' '0.25+0.25' '0.75-0.25' '0.05+0.05' \
	 '1+0.5' '0.5+1' '10+0.5' '0.5+10' '100+0.5' '0.5+100' '1.5+10' '10+1.5' '0.001+0.002' \
	 '0.002-0.001' '.ratio + 1' '1 + .ratio' '.ratio + .port' '.ratio * 1' '1 * .ratio' \
	 '.items|map(.id*1.5)|add' '.items|map(.id+0.25)|add' '.ratio + .ratio' '.ratio - .ratio' \
	 '(-0.5)|round' '(-1.5)|round' '(-0.4)|round' '(-0.6)|round' '(-1.4)|round' '0.5|round' \
	 '.ratio * .ratio' '.ratio == .name' '.name + .txt' '.tags[0] + .name' '.limits.rps + .port' \
	 '.ratio < .port' '.ratio >= .port' '.port * .port' '.name == .txt' '.tags[0] * 2' \
	 '[1,2.5]|add' '[1.5,2.5]|add' '[-1.5,2]|add' '[null,1]|add' '["a",null]|add' '[1,null,2]|add' \
	 '[[1],[2]]|add' '[1.5,null,2]|add' '[.ratio,.port]|add' \
	 '.limits|add' '.items|add' '.tags|add' '.limits + .limits' '.limits|length' \
	 '.items[]|[.]' '.tags[]|[.]' '.items[]|[.id]' '.items[]|[.,.]' '.items[]|[.[]?]' \
	 '.items[]|select(.id>1)|[.]' '.items[]|[.id]|add' '.items|map(.k)|[length]' '.items[]|[.k,.id]' \
	 '.items[0]|[.]' '.items[]|[.id]|length' '.items[]|[select(.id==1)]' '.nest[]|[.]' \
	 '[.items[]]|length' '.items[]|[.[]]|length' '.limits|[.]' '.items[]|[.id*2]' \
	 'del(.port)' 'del(.port,.ratio)' 'del(.limits.rps)' 'del(.tags[0])' 'del(.missing)' \
	 'del(.limits)' 'del(.)' '[.tags[]|del(.)]' '.tags|map(del(.))' 'del(.port)|has("port")' \
	 'del(.txt)' 'del(.utf)' 'del(.items[1].k)' 'path(.port)' 'path(.limits.rps)' \
	 'del(.nest[0])' 'del(.items[0].id)' 'del(.tags[0])|.items|length' 'del(.limits)|keys|length' \
	 'del(.items[1].k)|.items[1]|keys|length' 'del(.nest[0])|.nest|length' 'del(.esc)|.esc|type' \
	 'path(.tags[0])' 'path(.)' 'path(.missing)' 'path(.a.b.c)' 'path(.tags[-1])' \
	 '[path(.a,.b)]' 'path(.a)|type' 'del(.port)|type' 'path(.port,.ratio)|length' \
	 'null+1' '1+null' 'null+.ratio' '.ratio+null' 'null+null' 'null+[1]' '[1]+null' \
	 '[1.5,2.5]|max' '["b","a"]|min' '["b","a"]|max' '[1,2.5]|max' '[null,1]|min' '[1,null]|max' \
 '[(0*-1),(0)]|max' '[(0),(0*-1)]|max' '[(0*-1),(0)]|min' '[(0),(0*-1)]|min' \
 'if .a>1 then .a else 0 end' 'if .a==5 then .a else 0 end' 'if (false,true) then "t" else "f" end' \
 '.items[]|if .id==1 then .k else 0 end' '[.items[]|if .id>1 then .k else empty end]' \
	 '["a",1]|min' '[1,"a"]|max' '[true,false]|max' '[true,false]|min' '[null,true,1]|max' \
	 '1.5/0.5' '10/4' '1/8' '0.5/0.25' '2.25/0.75' '2.5/0.5' '1/0.0001' '100/8' '1.5/3' \
	 '10%2.5' '4.5%1.5' '(-3)%2' '7%2' '0%5' '5%0' \
	 '5.5%2' '7%3.5' '2.5%1' '1%0.3' '0.1%0.05' '3.3/1.1' '.ratio/.port' '.port/.ratio' \
	 '.ratio/.ratio' '1.0/0.5' \
	 '(1,2,3) + (100,200)' '(1,2,3) - (100,200)' '(100,200) + (1,2,3)' \
	 '(1,2,3) + (100,200,300)' '(1,2) + (3,4)' \
	 '[1,2,3]|keys' '[]|keys' '.nest|keys' '.limits|keys' '[.tags[]]|keys' '.nest[1]|keys' \
	 '18446744073709551615' '18446744073709551616' '9223372036854775808' \
	 '100000000000000000000' '12345678901234567890' '(-9223372036854775808)' \
	 '9223372036854775807+1' '18446744073709551615|.+0' '18446744073709551615|length' \
	 '0*-1' '(-1)*0' '0.0*-1' '(0*-1)|tostring' '(0*-1)|tojson' '(0*-1)|type' \
	 '(0*-1)==0' '(0*-1)<0' '(0*-1)>0' '(0*-1)+0' '[(0*-1),0]|sort' '[(0*-1)]|add' \
	 '.items[]|.id * 2' '.items[]|.id + 1' '.items[]|.id == 1' '.items[]|.id > 1' \
	 '.items[]|.id, .k' '.items[]|if .id==1 then 1 else 2 end' '[.items[]|.id * 2]' \
	 '[.items[]|.id + 1]' '[.items[]|.id % 2]' '(.items[]|.id) * 2' '.items[].id * 2' \
	 '(.items[0],.limits)|.rps?' '(.items[0],.limits)|.id?' '[..|numbers]|length' \
	 '[.items[]|tojson|fromjson]|length' '[.items[]|tojson|fromjson]|map(.id)' > $(PARITY_CASES); \
	exact=0; unsup=0; invalid=0; differs=0; \
	for mode in c plain r; do \
	  flag=""; if [ "$$mode" = "c" ]; then flag="-c"; fi; \
	  if [ "$$mode" = "r" ]; then flag="-r"; fi; \
	  while IFS= read -r f; do \
	    jout=$$(jq $$flag "$$f" $(PARITY_DOC) 2>/dev/null); jrc=$$?; \
	    if [ $$jrc -ne 0 ]; then invalid=$$((invalid+1)); \
	      printf '  jq refuses  %s\n' "$$f" >> $(PARITY_REJECTS); continue; fi; \
	    oout=$$(./$(BIN) $$flag "$$f" $(PARITY_DOC) 2>/dev/null); orc=$$?; \
	    if [ $$orc -ge 2 ]; then unsup=$$((unsup+1)); \
	      if [ "$$mode" = "c" ]; then echo "  REFUSED  $$f"; \
	        echo "    $$(./$(BIN) $$flag "$$f" $(PARITY_DOC) 2>/dev/null | head -1)"; \
	      fi; \
	    elif [ "$$oout" = "$$jout" ]; then exact=$$((exact+1)); \
	    else differs=$$((differs+1)); echo "  DIFFERS  $$f"; \
	      echo "    jq    $$jout"; echo "    oojq  $$oout"; fi; \
	  done < $(PARITY_CASES); \
	done; \
	valid=$$((exact+unsup)); \
	echo ""; echo "  oojq parity against jq"; echo "  ---------------------------"; \
	echo "  byte-identical  $$exact"; \
	echo "  unsupported     $$unsup"; \
	echo "  jq rejects case $$invalid  (not a parity requirement, listed below)"; \
	if [ -s $(PARITY_REJECTS) ]; then \
	  echo "  the cases jq ITSELF refuses, printed because a counter nobody can read is a counter nobody can hold to:"; \
	  sort -u $(PARITY_REJECTS); fi; \
	echo "  answered differently $$differs  (listed above)"; \
	if [ $$valid -gt 0 ]; then echo "  parity          $$((exact*100/valid))% of cases jq accepts"; fi; \
	echo ""

# --- Coverage smoke signal ---------------------------------------------------
#
# This is not coverage and does not claim to be. It counts, per dispatched
# builtin, how many behaviour assertions and how many parity cases name it. It
# cannot tell an assertion that exercises a builtin from one that merely mentions
# the word, and a count of 12 is not twelve behaviours. What it does catch is the
# one failure that matters here: a builtin no test reaches at all, which would
# print 0 0. leaf_paths printed 0 and had been shipping untested, and no other
# gate in this Makefile noticed. Two columns, because parity and the behaviour
# suite are different oracles: booleans and objects are reached by parity alone.
#
# The name list is read from the same place the suggestion list is, so a builtin
# that dispatches but cannot be suggested still shows up here.
coverage:
	@names=$$(mktemp); \
	grep -oE 'list_push\(n, "[^"]+"\)' filter/run/eval_suggest.oo \
	  | sed 's/.*"\(.*\)".*/\1/' | sort -u > $$names; \
	asserts=$$(mktemp); corpus=$$(mktemp); \
	grep '^[[:space:]]*assert_' $(MAKEFILE_LIST) > $$asserts; \
	sed -n '/^parity: build/,/^clean:/p' $(MAKEFILE_LIST) \
	  | grep -oE "'[^']+'" | tr -d "'" > $$corpus; \
	echo "  assertions + parity cases naming each dispatched builtin, thinnest first"; \
	echo "  -------------------------------------------------------------------"; \
	while IFS= read -r n; do \
	  pat="(^|[^a-zA-Z0-9_])$$n([^a-zA-Z0-9_]|$$)"; \
	  a=$$(grep -cE "$$pat" $$asserts); c=$$(grep -cE "$$pat" $$corpus); \
	  printf '  %3d test  %3d parity  %s\n' "$$a" "$$c" "$$n"; \
	done < $$names | sort -n; \
	rm -f $$names $$asserts $$corpus; \
	echo ""

# --- Corpus-blind differential sweep ----------------------------------------
#
# The parity corpus above only grows where a divergence was already found, so it
# confirms and never discovers. These probes are deliberately outside it, which is
# the only way a class of input nobody thought of ever gets looked at. Two real
# bugs came out of the first run: max compared with > and so kept the earlier of
# two equal values, and an if branch was handed the condition's answer instead of
# the value the condition was asked of.
#
# Two rules are encoded in how this runs, both learned by breaking them:
#
#   1. Compare through files with cmp, never through $(...). $(...) drops NUL
#      bytes from both sides, so a value holding one compares equal to a value
#      that is simply absent.
#   2. Never truncate a reference run. Piping jq into head -1 on a filter that
#      answers several times hides the shape of the answer, and it is how this
#      project came to believe that an if reads only the first answer. The whole
#      stream is printed below for every divergence.
#
# Refusals count as a pass, not a failure: a probe oojq declines to answer is the
# documented behaviour, and the refusal is reported so it can be checked by hand.
SWEEP_CASES = qa/sweep_cases.txt
SWEEP_DOC = /tmp/oojq_sweep_doc.json

sweep: build
	@if ! command -v jq >/dev/null 2>&1; then \
	  echo "SKIP: jq is not installed, so there is nothing to compare against"; exit 0; \
	fi; \
	: > $(SWEEP_REJECTS); \
	printf '%s\n' '{"name":"api","port":8080,"ratio":1.5,"neg":-7,"zero":0,"ok":true,"off":false,"nothing":null,"a":5,"tags":["prod","edge"],"limits":{"rps":500,"burst":750},"items":[{"id":1,"k":"a"},{"id":2,"k":"b"},{"id":3,"k":"a"}],"txt":"Hello World","esc":"a\"b\\c\nd\te","utf":"héllo","nest":[[1,2],[3],[]]}' > $(SWEEP_DOC); \
	cases=$$(mktemp); jf=$$(mktemp); of=$$(mktemp); \
	grep -v '^[[:space:]]*#' $(SWEEP_CASES) | grep -v '^[[:space:]]*$$' > $$cases; \
	exact=0; unsup=0; invalid=0; differs=0; \
	for mode in c plain r; do \
	  flag=""; if [ "$$mode" = "c" ]; then flag="-c"; fi; \
	  if [ "$$mode" = "r" ]; then flag="-r"; fi; \
	  while IFS= read -r f; do \
	    [ -z "$$f" ] && continue; \
	    jq $$flag "$$f" $(SWEEP_DOC) > "$$jf" 2>/dev/null || { invalid=$$((invalid+1)); \
	      printf '  jq refuses  [%s] %s\n' "$$mode" "$$f" >> $(SWEEP_REJECTS); continue; }; \
	    ./$(BIN) $$flag "$$f" $(SWEEP_DOC) > "$$of" 2>/dev/null; orc=$$?; \
	    if [ $$orc -ge 2 ]; then unsup=$$((unsup+1)); \
	    elif cmp -s "$$jf" "$$of"; then exact=$$((exact+1)); \
	    else differs=$$((differs+1)); echo "  DIFFERS  [$$mode] $$f"; \
	      echo "    jq    $$(tr '\n' '|' < "$$jf")"; \
	      echo "    oojq  $$(tr '\n' '|' < "$$of")"; fi; \
	  done < $$cases; \
	done; \
	rm -f $$cases $$jf $$of; \
	valid=$$((exact+unsup)); \
	echo ""; echo "  corpus-blind sweep"; echo "  --------------------"; \
	echo "  byte-identical  $$exact"; \
	echo "  refused         $$unsup"; \
	echo "  jq rejects case $$invalid  (not a parity requirement, listed below)"; \
	if [ -s $(SWEEP_REJECTS) ]; then \
	  echo "  the cases jq ITSELF refuses, printed because a counter nobody can read is a counter nobody can hold to:"; \
	  sort -u $(SWEEP_REJECTS); fi; \
	echo "  answered differently $$differs  (listed above, full streams)"; \
	if [ $$valid -gt 0 ]; then echo "  agreement       $$((exact*100/valid))% of cases jq accepts"; fi; \
	echo ""

install: build
	@mkdir -p $(HOME)/.openooda/bin
	cp -a $(BIN) $(HOME)/.openooda/bin/oojq
	@chmod +x $(HOME)/.openooda/bin/oojq
	cp -a uninstall.sh $(HOME)/.openooda/bin/oojq-uninstall
	@chmod +x $(HOME)/.openooda/bin/oojq-uninstall
	@echo "installed $(HOME)/.openooda/bin/oojq and oojq-uninstall"

uninstall:
	@rm -f $(HOME)/.openooda/bin/oojq /usr/local/bin/oojq $(HOME)/.local/bin/oojq /usr/bin/oojq $(HOME)/.openooda/bin/oojq-uninstall /usr/local/bin/oojq-uninstall $(HOME)/.local/bin/oojq-uninstall /usr/bin/oojq-uninstall
	@rm -rf $(HOME)/.cache/oojq $(HOME)/.config/oojq
	@echo "uninstalled oojq"

VERSION ?= $(shell cat VERSION 2>/dev/null || echo 0.1.0)

package-deb: $(BIN)
	@mkdir -p dist/deb-root/DEBIAN dist/deb-root/usr/bin
	@sed "s/^Version:.*/Version: $(VERSION)-1/" packaging/debian/control.binary > dist/deb-root/DEBIAN/control
	@cp $(BIN) dist/deb-root/usr/bin/oojq
	@chmod 0755 dist/deb-root/usr/bin/oojq
	@cp uninstall.sh dist/deb-root/usr/bin/oojq-uninstall
	@chmod 0755 dist/deb-root/usr/bin/oojq-uninstall
	@dpkg-deb --build --root-owner-group dist/deb-root dist/oojq_$(VERSION)-1_amd64.deb
	@rm -rf dist/deb-root
	@echo "built dist/oojq_$(VERSION)-1_amd64.deb"

package-rpm: $(BIN)
	@mkdir -p ~/rpmbuild/SOURCES ~/rpmbuild/SPECS ~/rpmbuild/RPMS
	@cp $(BIN) ~/rpmbuild/SOURCES/oojq-linux-x86_64
	@cp uninstall.sh ~/rpmbuild/SOURCES/uninstall.sh
	@sed "s/^Version:.*/Version: $(VERSION)/" packaging/oojq.spec > ~/rpmbuild/SPECS/oojq.spec
	@rpmbuild -bb ~/rpmbuild/SPECS/oojq.spec
	@cp ~/rpmbuild/RPMS/x86_64/oojq-$(VERSION)*.rpm dist/
	@echo "built dist RPM package"

package-arch: $(BIN)
	@mkdir -p dist/arch-pkg/usr/bin
	@cp $(BIN) dist/arch-pkg/usr/bin/oojq
	@chmod 0755 dist/arch-pkg/usr/bin/oojq
	@cp uninstall.sh dist/arch-pkg/usr/bin/oojq-uninstall
	@chmod 0755 dist/arch-pkg/usr/bin/oojq-uninstall
	@printf "pkgname = oojq\npkgbase = oojq\npkgver = $(VERSION)-1\npkgdesc = Capability-bounded jq replacement with stdio MCP\nurl = https://github.com/openOODA-tools/oojq\nbuilddate = $$(date +%s)\npackager = openOODA-tools <ops@openooda.org>\nsize = $$(stat -c %s $(BIN))\narch = x86_64\nlicense = Apache-2.0\ndepend = glibc\nprovides = oojq\n" > dist/arch-pkg/.PKGINFO
	@tar --zstd -cf dist/oojq-$(VERSION)-1-x86_64.pkg.tar.zst -C dist/arch-pkg .PKGINFO usr
	@rm -rf dist/arch-pkg
	@bash -n packaging/arch/PKGBUILD
	@cp packaging/arch/PKGBUILD packaging/PKGBUILD
	@echo "built dist/oojq-$(VERSION)-1-x86_64.pkg.tar.zst and validated PKGBUILD"

package: package-deb package-rpm package-arch

clean:
	@rm -rf dist .ooda-cache
	@echo "cleaned"
