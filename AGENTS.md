# oojq: House Laws & Where To Start

Status: **CLI works, 61% byte-compatible with jq 1.8.1**. `parse/`, `filter/`,
and `render/` are implemented and `main.oo` wires them to argv. `make parity`
is the measurement, not a claim. The MCP stdio surface and the AF_UNIX socket in
`ipc/` are still to build.

## 1. What oojq Is

A jq replacement. Read a JSON document, apply a filter expression, emit values
as JSON text. It behaves like `jq` closely enough that muscle memory transfers,
and it reaches the same answer or fails loudly rather than guess.

## 2. The Four Domains

Work lands in exactly one domain at a time. Each anchor.oo states its contract.

| Domain | Job | Does not do |
|---|---|---|
| `parse/` | JSON text to value tree | write anything, or evaluate filters |
| `filter/` | filter text to value stream | touch FS or net, or render text |
| `filter/builtin/` | the jq builtins | parse filters, or render text |
| `render/` | value stream to JSON text | decide which values exist |
| `ipc/` | CLI, MCP stdio, AF_UNIX socket | reimplement parsing or filtering |

The CLI in `main.oo` is done. `ipc/read_source.oo` holds the file and stdin
reader; the other two `ipc/` surfaces are stubs.

## 3. The Page Rule

Every `.oo` and `.oot` page is 16 to 256 lines. A shim — a file whose every
non-comment line is an import — skips the 16-line floor but never the ceiling.

At most 8 pages per directory, counting tests. This is the limit that forces a
tool to be split into readable pieces rather than one large file.

Never name a page `util.oo`, `utils.oo`, `helper.oo`, `helpers.oo`,
`common.oo`, `misc.oo`, `shared.oo`, `base.oo`, or `core.oo`. A vague name is a
refusal to decide what the page owns. Use a verb: `parse_document.oo`,
`decode_number.oo`.

Imports are relative string literals. There are no `::` namespaces.

## 4. The 4-Element Academy Header

Mandatory on every page, all four elements within the first 7 lines. **The gate
reads `head -7`**, so `Logline:` and `Setup:` must each occupy exactly one line.
A wrapped sentence pushes `Beats:` to line 8 and fails the build.

```
1  // # Title
2  //
3  // Logline: One sentence saying what this page does.
4  //
5  // Setup: What it needs and what it refuses.
6  //
7  // Beats:
8  //   1. ...
```

## 5. Capability Discipline

Zero ambient authority. Every function that touches the outside world takes the
explicit token it needs: `FsReadCap`, `FsWriteCap`, `BindCap`, `ProcessCap`.

Never `/bin/sh -c`. Use an explicit argv array. No shell, no PATH lookup.

Every file descriptor is opened `O_CLOEXEC`, so a child process can never
inherit a listener or a live connection.

Validation is negative-trust and fails closed: a malformed filter is refused
with a located message, never silently coerced into a different filter that
returns a confident wrong answer.

Double-run determinism is required. Two runs over identical input must produce
identical bytes. `make test` asserts this for both a scalar filter and an
iterating one.

`process_exit` is classified under `ProcessCap`. `main`'s return value does NOT
set exit status, so a non-zero status must be raised explicitly. oojq holds that
token for that reason alone.

## 6. Runtime Traps Already Found

Do not rediscover these. Each one cost real debugging time.

### A warm `.ooda-cache` will tell you a broken build is fine

This one hid for a while and it is the most dangerous item on the page, because it
makes a gate pass. `oodac build` keys its cache on the files it read, so a page
carrying a syntax error can keep reporting the artefact of an earlier good
compile. `filter/run/eval_join.oo` held `-> Result[SRes, String> {` — a `>`
where the `]` belongs — and `suffix_on` also called `edge_index` before writing
it. Both were in the tree while `make build` and `make verify` were green.

`rm -rf .ooda-cache` before believing a green build, and once before any gate run
that is meant to prove something. Two habits follow:

- **A malformed generic is reported somewhere else entirely.** The error pointed
  at a `return` several lines below the damage and printed the whole rest of the
  file as the offending type. Do not read the reported line; read the reported
  *type*. When a page that checked fine yesterday fails today over a type that
  looks right, scan for a bracket that does not close:
  `python3 -c "…l.count('[')!=l.count(']')…"` over every page, ignoring lines
  that contain a quote.
- **A function must be defined before it is used, within a page as well as
  across pages.** `edge_index` was written below `suffix_on`, which asked it of
  every `first` and `last`. The build never noticed, because of the cache.

Do not trust a green build on a tree you have just restructured. Prove it cold.

### A step that reads the whole input stream is the same bug every time

jq applies every step above a field access to **one input value at a time**.
oojq read the entire stream in one go in three places at once, and every one of
them was a wrong answer rather than a refusal:

- **A binary operator paired across values.** `.items[]|.id * 2` answered
  `2 4 6 2 4 6 2 4 6`. The left side over three values is three, the right side
  `2` over three values is *also* three — a constant is not free of its input —
  and the cross product of the two is nine. `(.items[]|.id) * 2` was right, which
  is why the corpus never saw it: it only ever had a widening operator whose
  right side was a wrapped `(.items[]|...)`.
- **A comma answered the whole left stream and then the whole right one.**
  `.items[]|.id, .k` was `1 2 3 "a" "b" "a"` where jq reads them in step:
  `1 "a" 2 "b" 3 "a"`. The values were a permutation of the right answer, which
  is the one class of wrong a corpus of *sets* cannot see.
- **An `if` read its branch over the whole stream.** `.items[]|if .id==1 then 1
  else 2 end` answered 27 values where jq gives three.

All three are now one rule and one loop: `per_value` in `filter/run/eval_run.oo`
walks the input a value at a time, and `eval_filter` gates every step that is not
a field access through it. `step_once` is what one value does. The corpus had
three hundred cases and not one put an operator, a comma, or a conditional
downstream of an iterate — the iterate was always consumed by `map`, `select`, or
a field. **A corpus needs cases where the *previous* step changes the arity of
the next one, not just cases where it does not.**

The same loop answers a question mark. `guarded` used to ask the whole stream at
once and turn the first refusal into *no* answers, so `(.a,.b)|.c?` was nothing
where jq gives `2`: the one value with a `c` was thrown away with the one that
had none. `per_value`'s `skip` flag is that, and it is why the loop is shared
rather than written twice.

### A verdict is not the value it was read from

`eval_if` walked the condition's answers and handed each one to the branch as the
branch's input. So `if .a>1 then .a else 0 end` on `{"a":5}` read `.a` of the
`true` the comparison produced and died with *cannot index a bool with "a"*. The
branch must see the value the condition was asked of. `.items[]|if .id==1 then .k
else 0 end` was the same failure, and it was invisible in every test that had been
written, because a branch made of constants cannot tell the two inputs apart.

Whenever a step reads a condition, a key, or a path, ask which value the *next*
step is supposed to see: the one that came in, or the one that was derived. jq
means the one that came in, always.

### A probe truncated to one line is not a measurement

This file's own rule is that expected values come from jq, not from hand
reasoning. Adding `| head -1` to a jq probe broke that rule quietly. `if
(false,true) then "t" else "f" end` printed `f` and the wrong rule — "the first
answer decides, and the branch runs once" — looked confirmed by six probes. Run
without `head`, `jq` answers `f` *and* `t`: the branch runs once per answer, each
over the original input. I had already written the bug into the source and into a
comment before re-measuring.

Never truncate a reference run. `$(...)` drops NUL bytes and `head -1` drops
answers; a filter that yields several values is precisely the case worth
measuring. Show the whole stream, then read it.

### An arena is never replaced, only grown

`fromjson` parses into a document of its own and handed that back as the step's
arena. At the top of a stream that is harmless, and `[.items[]|tojson|fromjson]`
was **nothing**: `per_member` threads one arena through the loop, so the moment
one member swapped it the indices already collected pointed into an arena
nobody was rendering. The rule is the one already recorded for `JDoc` — a step
appends to the arena it was handed and hands the grown one back. A step that
builds a value of its own has to copy that value into the caller's arena.

### A filter argument that is read and ignored is worse than one refused

`paths(f)` kept the paths `f` is true of. The walk emitted **every** path and
never looked at `f`: `[paths(.=="a")]|length` was 16 where jq gives 2, and
`[paths(empty)]` was 16 where jq gives 0. Both look like plausible answers, which
is exactly why a wrong answer here survives. The walk lives on a page that cannot
reach the evaluator, so `f` cannot be asked; it is now refused by name. When a
builtin takes a filter and cannot run it, refuse — never run it without.

### A number is not an Int, and an Int is not every number

`JVal.ival` is a 64-bit `Int` and `JVal.sval` is text. Three separate silent
corruptions lived in that gap, and none of them was a refusal:

- **A literal wider than an Int wrapped.** `decode_number` did
  `acc = acc * 10 + d` with no bound, so `18446744073709551615` decoded to `-1`
  and `100000000000000000000` to `7766279631452241920`. jq keeps the written
  digits. `fits_int_text` in `parse/decode_number.oo` now asks the question
  first, and a literal that does not fit is carried as its own text, which is the
  same node kind a float already used.
- **An int-by-int multiply wrapped.** `eval_op.oo` had a fast path
  `int_result(doc, a.ival * b.ival)`, so `9223372036854775807 * 2` answered
  **-2** and `3037000500 * 3037000500` answered nonsense. The digit path is exact
  at any size and `num_node` hands an `Int` back whenever the answer still fits
  one, so the fast path bought nothing and cost two wrong answers.
- **A negative zero was not a number.** `0 * -1` answered `0` where jq writes
  `-0`, and `num_cmp` called `-0 < 0` because it read the sign before asking
  whether the value was zero. `num_norm` keeps the sign of a zero now, `num_mul`
  puts the sign on by hand rather than through `num_neg` (which leaves a zero
  alone, because jq's `abs` of a computed `-0` is `-0`), and `num_cmp` asks the
  zero question first.

**Where a big number differs from jq, oojq is right and the divergence is named.**
`9223372036854775807 + 1` is `9223372036854775808` here and `9223372036854776000`
in jq, because jq's answer is the double next to it. The *literal* cases are
byte-identical: `18446744073709551615` prints as itself in both.

### Two names for one idea are not the same operation

`fabs` was added by aliasing it to `abs` through `math_over`, which cost nothing
and was wrong. In jq the two are different functions on one interesting input:
`abs` is `if . < 0 then -. else . end`, and `-0 < 0` is false, so `abs` leaves a
computed `-0` alone and `(0*-1)|abs` is `-0`. `fabs` is the C function, which
clears the sign bit, so `(0*-1)|fabs` is `0`. An alias would have answered `-0`
where jq answers `0`.

Measure the *shared* input, not the shared name. Whenever two spellings meet at
one dispatch line, find the single value where they part company and give each
its own answer. `abs` still goes through `num_neg`; `fabs` builds the `Num` with
`neg: false` because that is the only difference between them.

### A regex engine that compiles a pattern it cannot honour must not answer

`test` handed the pattern to the std NFA, which reads it one character at a time
and has no escape, group, counted repetition, class range, or negated class. The
validator accepts every one of those as well formed, so the engine answered a
confident `false` where jq answers `true` — `test("a\\.c")`, `test("(ab)c")`,
`test("a{1}")`, `test("a\\d")`, `test("[a-z]")`, `test("[^a]")`, `test("[A-Z]")`.
A `false` from `test` drops the rows it was meant to keep, so this is worse than
saying nothing. `pattern_gap` in `filter/builtin/builtin_string.oo` names the
construct and refuses; literals, `.`, `*`, `+`, `?`, `|`, `^`, `$` and a plain
`[abc]` still go through untouched. **The lesson is the std validator's: a
checker that accepts what the engine cannot do is a checker that turns a wrong
answer into a confident one.**

### An index minted as text is a different value, not a rendering

`keys` on an array answered `["0","1"]` where jq gives `[0,1]`, because it pushed
`i.to_string()` while `keys_unsorted` beside it minted `jval_int(i)`. Nothing
downstream noticed: `.a|keys|add` answered `"01"`, and a corpus of shapes saw an
array of strings where an array of numbers looks the same in a diff. The two
builtins are the same read with a sort between them, so they belong on one page,
and `index_keys` is the one loop both of them use.


These are recorded first because they share a cause. The rule that found them
is: **when a fix lands, ask what class of input was never in the corpus at
all.** A passing score measures the corpus, not the program. In every case
below the corpus had the right *shape* and the wrong *contents*, so every case
in it passed while a neighbouring case was silently wrong.

- **A binary operator fed its right operand the left operand's value.**
  `eval_bin` called `eval_filter(ast, right, live, one(here))`. jq evaluates
  both sides against the input the expression was given, so `.a + .b` is two
  members of one object. oojq evaluated `.b` against `.a`'s value, so the tree
  was right and the data was wrong: `.ratio + .port` raised `cannot index a
  float with "port"`, `.[0] + .[1]` on `[1,2]` raised `cannot index a int`,
  and `.items[] | .id + 0.25` only worked because a literal ignores its input.
  **Every case in the corpus with a `.` on the right of an operator was a
  literal, a subscript of `.` itself, or a wrapped `(.a)`.** `.a + .b` — the
  single most common jq idiom there is — was never in it.
- **A binary operator paired its values left-outer; jq pairs right-outer.**
  `(1,2,3) + (100,200)` is `101 102 103 201 202 203` in jq and was
  `101 201 102 202 103 203` here. Every value was right and only the order was
  wrong, which is the kind of gap a corpus of *answers* cannot see and a corpus
  of *streams* can. The fix is to evaluate the right side **once** and then walk
  it outer, calling `append_pairs` with the whole left list — which also stops
  re-evaluating the right side once per left value. This is the one place the
  frozen hub was edited rather than worked around, and it cost exactly one line
  of comment budget to fit.
- **`add` read the integer part off every member.** `sum_ints` summed `e.ival`
  over an array, and `ival` is meaningless on a float node, so `[1, 2.5]`
  answered `1` with the `2.5` dropped and no complaint. It refused only when
  the *first* member was a float, which is why `[1.5,2.5]|add` said no and
  `[1,2.5]|add` said a wrong number. jq's `add` is `reduce .[] as $x (null;
  . + $x)`, and every one of its answers follows from folding `+` from null.
- **`min` and `max` compared `ival` too.** So `[1.5,2.5]|max` answered `1.5`
  (both members read 0, so nothing replaced the first) and `["b","a"]|min`
  answered `"b"`. They belonged on the ordering page all along, next to the
  comparator that already did this correctly.
- **`jq`'s `%` is not a remainder.** It truncates **both** operands to integers
  and then takes an integer remainder: `5.5 % 2` is `1`, `7 % 3.5` is `1`, and
  `1 % 0.5` is refused because `0.5` truncates to the zero divisor. Measured
  across twenty-one probes, all consistent with that reading and none with a
  real remainder. The answer jq writes does not satisfy `a = q * b + r`:
  `7 = 2 * 3.5 + 1` is false. This page answered the true remainder for a while,
  on exactly that argument, and it was **wrong to**. "More exactly than jq" is not
  "better than jq" when what jq does is a deliberate, measured choice a migrating
  script can depend on: the two answers differ on a non-integer operand and
  *nothing errors*. `5.5 % 2` returning `1.5` where the tool elsewhere reproduces
  jq's `1` is unacceptable in a tool whose selling point is jq compatibility. It
  matches jq now, and the arithmetic case is still a good one — it just was not
  the question being asked. Before claiming a divergence is an improvement, work
  out which of the two it is.
- **A quotient is not dyadic, so `/` cannot go through `decimal_bits` the way
  `+ - *` do.** It is written in `filter/eval/float/flt_div.oo` and the shape is
  worth keeping. Long-divide seventeen digits of each operand (seventeen is the
  most a 63-bit `Int` holds while leaving `remainder × 10` under the top of the
  range), scale the result back into the operands' units, take the **exact**
  residual with `dd_mul`, and long-divide *that* by the divisor for eighteen more
  places. Thirty-three digits, a thousand past what the rounding can notice. The
  scaling step is the one that is easy to get wrong: a residual taken before
  scaling is `5e-324 - 2 × 2.5 = -5` rather than a tiny number, and every subnormal
  pair answers nonsense or hangs. Then round once with `decimal_bits` and **prove**
  it: build the two midpoints bordering the candidate exactly, multiply by the
  divisor exactly, compare with the dividend exactly, and keep the candidate only
  if it holds on both sides. Resting on "a tie is unlikely" is a guess in proof's
  clothing; the comparison is the proof, and it costs three exact multiplies.
- **A fast path that refuses is not a fast path.** `/` keeps the exact long
  division for two whole numbers because it alone can answer a quotient past 53
  bits. But that path *refuses* a non-terminating quotient and one too wide for an
  `Int`, and both are cases jq answers — so the double takes over on refusal
  rather than letting the refusal stand. `1/3` is jq's `0.3333333333333333` where
  it used to be an error, while `10/4` is still the exact `2.5`. `+ - *` never had
  this problem: theirs computes or clamps and only then refuses, so keeping them
  exact cost nothing. The asymmetry is the reason, and it is worth checking whether
  a "keep the exact path" decision has a refusal in it before making it.
- **A path walk must cut only inside the member the path already matched.**
  `del(.tags[0])` handed the steps after `tags` to *every* member of the object,
  so it also dropped `items[0]` and `nest[0]` and returned a document smaller
  than the one it was given. Both new divergences the first `del` corpus
  produced were this, and neither showed up in the hand-written cases because
  every one of those deleted into an object with a single relevant member.
  **When a corpus case passes but its siblings were not checked, ask what else
  the same code touched.** The fix is to pass the cut as an explicit flag rather
  than to infer it from whether the remaining steps happen to be empty.
- **`List[List[String]]` does not survive the backend; `List[List[Int]]` does.**
  `oodac check` passed and the build failed in LLVM with `'%t60' defined with
  type '%OoLL_S' but expected '%OoSList'` — the outer list handed over where the
  inner one was wanted. `group_runs` in `eval_sort.oo` builds `List[List[Int]]`
  by the same `list_push` and is fine, so the difference is the element type
  and not the nesting. **Never return or accumulate a list of lists of
  strings.** Split in the caller and loop instead; `path` and `del` do that for
  exactly this reason.
- **A `JDoc` passed by value into a call is gone afterwards, and `oodac check`
  does not say so.** The arena grew in `eval_bin` and was then used to build the
  next seed after it had already been passed to `eval_filter`. `oodac check`
  reported `OK`, the build reported `OK`, and the binary answered *nothing* for
  every operator — exit 1, no output, no error — because each minted index
  pointed into an arena that was not the one handed back. The symptom is the
  tell: a filter that used to work now answers empty, not an error.
  **A `JDoc` is single-owner. Take it from the result, pass it once, and take
  the next one from the result of that call.** The same trap in a `String` or a
  `List` is caught by the checker, which makes the `JDoc` case the dangerous
  one.
- **Reading `.ival` is never safe for a value whose kind you have not checked.**
  Three separate functions did it. When in doubt, go through `num_of` and the
  digit runs, or through `compare_values`, which already folds both number
  kinds into one number.

### The hub is dense, not frozen

`filter/run/eval_run.oo` sits at its 256-line ceiling and is the only page that
calls `eval_text` and `eval_filter`, so nothing that needs either can move off
it. For a long time that was written down as "frozen", and six builds were spent
on a per-value collect that could not be added. The mistake was the *question*.
The note said "gather needs a loop over the values, and gather cannot grow".
The right question was **"who already loops over the values?"** — and the answer
was two lines away, in `per_member`, which walks `input` one value at a time and
gathers each value's answers for `map`. A collect is `map` pointed at the value
itself instead of at its members. So `gather` became a call with a different
mode, four conditions in `per_member` grew an `|| mode == "collect"`, and the
impossible loop was a mode. Nothing was added to the hub; a line came back.

**A page at its line ceiling is a constraint on writing, not on designing.** When
a change will not fit, the first move is to find the loop it duplicates, not to
find a line to delete. The comment budget is the last place to look, because
every comment deleted to make room is a decision that cannot be read back.

**And check that the page you blame is the page that is actually full.** The
feature queue had been written down as "blocked on the hub" for an increment,
because the hub was the page that had to *call* the new code. But the page that
had to *hold* the new code was `filter/eval/eval_builtin.oo`, which was also at
256 — and nobody had counted it, because the queue recorded where the call goes
and not where the code lives. Moving `one_step`, `math_over`, `sqrt_over`, and
`regex_gap` to `filter/eval/leaf/leaf_step.oo` took that page to 140 and freed
116 lines. The hub did not move at all, and the queue is no longer blocked.

The move was legal because the import graph has no path back: `jval_object` and
`select_node` sit under `parse/`, every render page reaches only `parse/`, and
the only importer of `filter/eval/anchor.oo` is the hub. Check the graph with
`grep -rn '^import'` before assuming a move creates a cycle, because the cycle
that would have blocked this one is the one a reader assumes exists.

**A chain of one-line `if` dispatch is data wearing a function's clothes.**
`one_step` was 55 lines of `if w == "x" { return builtin_x(...); }`. That is not
control flow, it is a table, and it grows by one line per builtin forever. Moving
it whole to its own page is the refactor that makes the next twenty builtins free
rather than twenty-one lines each.

### Where a shared helper is allowed to live
`filter/builtin/anchor.oo` re-exports every builtin page, and almost everything
under `filter/eval/` and `filter/run/` imports it. So **no page under
`filter/builtin/` can import anything under `filter/eval/` or `filter/run/`**,
and the cycle is through the anchor, not through the named page. Three
helpers had to be placed against that rule rather than against their subject:

- The refusal sentence `cannot_pair` went to `render/render_value.oo`, beside
  the `shown_value` it is built from. It cannot go in `filter/select_node.oo`,
  because `render_value.oo` already imports that page.
- `min_over`/`max_over` went to `filter/run/eval_sort.oo`, which is the
  ordering page, holds `compare_values` already, and is imported by the
  dispatcher. They cannot go in `filter/builtin/builtin_string.oo`, where they
  were, because the comparator they need is out of their reach.
- `add` moved to `filter/eval/eval_op.oo` as `array_add`, because it is a fold
  over `op_add` and the fold belongs next to the operator it folds. It cannot
  stay in `filter/builtin/builtin_core.oo` for the same reason.
- `num_node` moved from `filter/eval/eval_op.oo` to `filter/eval/eval_leaf.oo`
  beside `num_of`, which is its exact inverse, because `eval_div.oo` needed it
  and `eval_op.oo` imports `eval_div.oo`. Every caller already imports
  `eval_leaf.oo`.

The general form: **the lowest reachable layer is the one no other page in the
cycle imports, not the one that looks lowest.**

### An update operator is a setpath call, and that is measured

jq's `.p |= f`, `.p += x`, `.p -= x`, `.p *= x`, `.p /= x`, and `.p //= x`
are each **exactly** the same answer as

    setpath(P; getpath(P) OP rhs)

for a literal path `P`. Checked against jq 1.8.1 on `.port`, `.missing`,
`.limits.rps`, and `.tags[0]`, and on `+=` and `//=` separately: every pair is
byte identical, including the no-op on a key that is not there. So an update
operator does not need a node kind and a mode; it needs `setpath` and a rewrite
in the parser that emits a `setpath` call with a `;` between two filters.

Two things that makes possible are already here. `range` takes one, two, or
three arguments separated by `;`, so the argument path can carry more than one
filter once a builtin is willing to split. And `path(f)` already reads a
literal path expression to the same array `setpath` would be handed, so the
parser does not have to build the path itself.

The parts that are not here yet: `setpath` does not exist, the `;` splitter is
private to `builtin_range.oo` and named `range_parts` on purpose, and there is
no assignment level in the grammar. Watch the page budget — `filter/run/` and
`filter/eval/` are both at eight pages, so a new page for `setpath` has to come
out of a directory that has a slot.

### A routed builtin needs both halves of the route

`route_builtin` is only reached when `is_routed(name)` is true, or the name is
`range`, or the call has no argument. Adding a dispatch line to
`route_builtin` and forgetting `is_routed` builds perfectly and answers
`unknown builtin` for every call **that has an argument** — which is every call
worth testing. A zero-argument builtin hides the mistake, because
`chars_len(body) == 0` routes it anyway. `is_routed` and `route_builtin` are
one decision written in two places, and the test that finds it is a case with
an argument, never one without.

### Language and toolchain

- `byte_at(s, i)` binds to `oo_byte_at`, which takes a **String**, not a
  `List[Int]`. On a byte buffer it fails at the LLVM stage with a struct-type
  mismatch. Read buffers with `list_get(buf, i) & 255`, as
  `json_zero_copy.oo` does.
- `match` is a statement, not an expression. `let x: T = match r { ... }`
  fails at the backend with `unsupported expr LBRACE`. Bind to a `let mut`
  inside the arms instead.
- **A digit run carries no sign, and a minus left in front of one is read as a
  zero.** `(-3) + 0` answered `3`, `(-3) | floor` answered `3`, `(-3) < 0`
  answered `false`, and `(-1.5) + (-1.5)` answered `3`. Every one of those was
  wrong and every one was silent. The cause was at the two ends of the number
  path: `num_from_int` called `num_norm(false, v.to_string(), "")`, which put
  `-3` into the *digits* with `neg` left false, and `num_node` read the digits
  back with `parse_digits`, where `digit_of("-")` is 0 and the minus simply
  vanishes. Two helpers, one bug, every arithmetic and comparison answer
  involving a negative integer wrong.
  **It survived a 99% parity score because no case in the corpus did arithmetic
  on a negative value.** The document had a negative member and the corpus read
  it, sorted it, and printed it, but never added to it. When a fix lands, the
  question to ask is not "is the failing case green" but **"what class of input
  was never in the corpus at all"** — a passing score measures the corpus, not
  the program. `(-3) + 0` is now a test, and the corpus carries forty more
  negative-arithmetic cases.
- **`let mut wide: String = rs;` moves `rs`, and a later read of `rs` is a
  use-after-move.** Binding a local from another local *moves* it, not copies it,
  so the shape that reads naturally — initialise the mutable one from the
  immutable one, then use the immutable one again in a branch — does not build.
  The fix is to leave the destination empty and assign from the source in each
  arm, so the source is read exactly once. The same applies to a struct field
  used twice: `v.ip + v.fp` moves both, so `chars_len(v.fp)` *after* that line
  sees nothing. **Measure a field into a local before joining it, and move a
  local exactly once.**
- **A duplicate function name silently mis-dispatches, and std counts too.** The
  usual scan is
  `grep -rhoE '^(pub )?fn [a-z_0-9]+' --include=*.oo . | sed 's/pub //;s/fn //' | sort | uniq -d`,
  and it only sees this tree. Writing `fn b64_val` in a page that also imports
  `std/core/encoding/base64.oo` bound to **std's** `b64_val`, which is not even
  `pub`: `"a-b_"|@base64d` decoded instead of being refused, because std's table
  carries the URL-safe alphabet jq rejects. Nothing warned. When a page imports a
  std module, check the names in that module too:
  `grep -oE '^(pub )?fn [a-z_0-9]+' ~/.openooda/std/<path>.oo`.
- **An array literal is not an expression.** `let divs: List[Int] = [1, 4, 16, 64];`
  type-checks and passes `oodac check`, then fails to emit with
  `unsupported expr LBRACKET`. A literal list inside a *filter* is fine, because
  that is parsed text; what will not build is a list written in `.oo` source.
  Build one with `bytes_new()` and `bytes_push`, or replace the lookup with a
  function of the index. This is the same shape of trap as the RPAREN one below:
  the checker passes and only the backend complains.
- There is no `const` keyword, and `Unit` is not a type. A function that returns
  nothing returns `Int` or `Bool`.
- **A function must be defined before it is used**, within a page as well as
  across pages. A forward reference inside one page makes the checker widen the
  return type to `Result[_, String]` and report a bogus mismatch. Define helpers
  above their callers.
- `list_set` and friends are declared for `List[Int]`. There is no `list_insert`
  in std; rebuild a list by pushing instead.
- A `&&` or `||` chain spanning several lines can confuse the checker's
  statement splitter. Prefer a sequence of `if` returns.
- **Never nest a call inside another call's argument list, and never pass one as
  an argument at all.** Two shapes break, and both messages point nowhere useful:
  - `jdoc_push(live, jval_string(list_get(k, i)))` type-checks and passes
    `make check`, then fails to emit with `unsupported expr RPAREN`.
  - The same nesting inside a helper call fails with
    `contract: missing LBRACE after fn header`.
  - `return Ok(some_fn(a, b));` is the same shape and fails the same way.
  Bind every intermediate to a `let` and pass the local. This cost a long
  bisect because `oodac check` passes and only `build` fails.
- A relative import may not escape its directory: `import "../x.oo"` is rejected
  as a path escape. From a nested page, import from the project root instead,
  as `filter/builtin/builtin_core.oo` does with `import "filter/select_node.oo"`.
- `list_set` is declared for `List[Int]` only. There is no generic form, so a
  `List[JVal]` arena cannot be written in place. Build containers after their
  children are known instead, and thread the arena through recursion.
- `read_stdin` binds to `oo_read_stdin`, which is present in `liboodar.a` but
  produces an undefined LLVM symbol. Use `oo_read_stdin_chunk(fs, ms)`, which
  links, and loop until it errors.
- A function taking `&FsReadCap` and calling `oo_read_stdin_chunk` works; the
  chunked reader returns `Err` on both timeout and EOF, so those are
  indistinguishable. This is why `read_source.oo` treats an error as end of
  input after an idle budget.

### std library

- `json_zero_copy.oo` reports a number as the offset **just past its last digit**
  and never materialises the digits: `num is the end offset ... no accessor
  materializes them`. Measured: `7` reports 1, `42` reports 2, `1234` reports 4.
  `decode_number.oo` exists solely to turn that byte range into an `Int`.
- That same design means the scanner stops at a dot, so `1.5` used to surface as
  a missing-comma error from the enclosing container. `parse/float_scan.oo`
  fixes it without touching std: it rewrites every float literal to digits of
  the **same byte width**, so each offset the std parser reports still addresses
  the original span, and it keeps the literal text for rendering.
- **`to_string` cannot take a Float.** `oodac/emit/llvm/ll_builtin_host.oo:220`
  maps `to_string` to `oo_int_to_str` for every argument, so `to_string(1.5)`
  emits `oo_int_to_str(i64 1.5)` and fails at the LLVM stage. The runtime exports
  `oo_print_double` but no double-to-string function. A float node therefore
  carries its source text instead of a `Float`, which is why float arithmetic
  cannot be printed yet.
- **The old claim that std has no JSON encoder is stale.**
  `std/core/format/json_writer.oo` is a complete fluent serializer with
  escaping. oojq still writes its own `render_string.oo` because
  `json_escape_str` covers only quote, backslash, and three whitespace bytes,
  and leaves every other control byte below 0x20 unescaped.
- `str_index_of` returns **byte** offsets while `str_slice` and `char_at` are
  **character** indexed. Composing them truncates silently on non-ASCII input.
- `char_at` is O(index), so character-by-character scanning is quadratic.
  `chars_len` is O(1) and `str_slice` is fast.
- `A "\0"` string literal compiles to an empty string. Build such a byte
  explicitly with `bytes_to_str(bytes_push(bytes_new(), 0))`.
- `byte_concat` cannot lower: it calls `bytes_concat`, which oodar implements
  and tests in C but never registered with the emitter. `str_concat` is the
  mirror trap, registered with the emitter but absent from the checker. Use `+`.
- `oo_bytes_from_str` exists in `liboodar.a` but has no emitter binding. Build
  the buffer one byte at a time with `bytes_push` and `byte_at`.
- `std/net/protocol/jsonrpc_*.oo` are destubbed to `Int` and cannot carry a real
  protocol. Do not build on them. `oogrep/mcp/` answers JSON-RPC on its own.
- `parse_int` is a std builtin at arity 1. Avoid the name.

### A test that cannot fail is worse than no test

`assert_out` compares through `$(...)`, and command substitution strips trailing
newlines. A filter that writes one empty line and a filter that writes nothing at
all both arrive as the empty string, so the suite could not tell them apart. Ten
assertions were written that way, and one of them — *-r of an empty string writes
an empty line* — passed even when the program wrote nothing whatsoever, which is
the exact opposite of what it claimed. Those ten now use `assert_bytes` and count
bytes on stdout, so 0 and 1 are different answers.

Command substitution also drops NUL bytes, so `$(...)` cannot be used to compare
a value that might contain one. Anything comparing against `jq` writes both sides
to a file and uses `cmp`. That is what `make sweep` does.

The wider point: an assertion whose failure mode is indistinguishable from its
pass is decoration. Ask what the test would report if the program were deleted
entirely, and if the answer is "the same thing", the test is not testing.

### A diagnostic you cannot locate is not a diagnostic you can migrate against

The `oodac` replaced on 2026-10-03 05:25 rejects the whole-program build with
`ERR move use after move w at 176`, and calls `filter/select_node.oo` an
unused import in `filter/run/eval_each.oo`. Both were run down and both are
wrong, by three independent tests:

1. **The line survives unrelated edits.** The error names `parse_lit.oo:176`
   and the page has no `w` at line 176. Replacing the `cur_end(w)` call there
   with a direct field read left the error at 176. A page is also blamed for an
   error inside something it calls, so `eval_run.oo` is named for a fault
   somewhere in the tree it reaches.
2. **The variable is not in the file.** `eval_run.oo` has no `w` anywhere —
   not at 176, not at all.
3. **The unused-import pass approves code that cannot compile.**
   `eval_each.oo` imports exactly one page, uses `array_result` and
   `concat_indices`, and those are declared in `filter/select_node.oo` and
   nowhere else in the project, in `std`, or in `northstar.oot`. Deleting the
   import still checks `OK` with exit 0; keeping it fails with exit 1. Run
   cold — a warm `.ooda-cache` will answer either question wrongly, which is
   how this looked like a scope change at first.

So the new compiler resolves `pub` symbols without the import graph saying so,
and its move pass cannot say where the fault is. **Do not rewrite this codebase
to satisfy it.** Restore the previous `oodac`, or fix symbol resolution and
diagnostic attribution first. A migration is only worth starting once the check
can name a real file, line, and variable.

### Taking a value out moves it, and the check below it reads it again

`per_member` took `let mut members: List[Int] = v.kids;` and then, three lines
below, asked `v.kind` — a name the compiler has already seen moved. The fix
costs no lines: the kind check moves *above* the take, because the check is
skipped for `select` and `collect` either way, so the reorder changes nothing
about what runs. `eval_each.oo` already carries a long note about the same trap
in the empty-collect page, which is why the rule is written down twice: once
where it bit, once where it is most likely to bite again.

### A correct lookup hides a malformed container

`{"a":1,"a":2}` was read as an object holding `a` twice, and `.a` answered `2` on
both binaries. Every spot check that went through a field access agreed, so the
duplicate looked like it was working: last write wins is exactly what a lookup
does. `keys` answered `["a","a"]`, `length` answered 2, and `to_entries` invented
a member that was never written, and none of those had ever been asked.

The lesson is not about duplicate keys. It is that *a lookup answering correctly
is evidence about the lookup and nothing else*. Every question that reads the
container as a whole — how many names, what names, in what order — is a different
question, and it is the one that finds a malformed structure. When a container is
built anywhere, ask what the whole-container question answers, not whether the
element question does.

That is also why the rule went into `jval_object` rather than into the two places
that got it wrong. The parser and `from_entries` were separate copies of the same
mistake, and `+` was a third copy that was already right. One chokepoint, one
rule: `put_member` in `parse/value_tree.oo`, which every way of building an
object passes through.

### Measure a fix against the build it replaces, not against nothing

Enforcing the rule above turned object construction into a fold over every
member, which is quadratic. A 8000-key object went to 44s and jq does it in
0.01s, and the obvious reading was that the fix was unaffordable.

Building the same tree with the old `jval_object` and timing it gave 44.07s
against the new 38.74s. The quadratic was already there, in `jdoc_push`, which
appends by rebuilding the node list. The fix cost nothing and hid a pre-existing
problem slightly better.

So the arena is the real finding: **an n-node arena costs O(n²) to build**, which
makes oojq the slower tool on any large document regardless of how good the
filter layer is. Before rejecting a change as too slow, time the state it was
replacing. A regression is a difference, and a difference needs two measurements.

### The quadratic is the language, and std does not get you out of it

Chasing that O(n²) to a fix is where the obvious move is wrong. `list_push`
copies, because a `List` append returns a new list. **There is no growable buffer
in openOODA, and the std collections that appear to be one are not:** `pvec_push`
in `std/core/collection/persistent_vector.oo` copies its whole element list on
every append, and `fhm_insert` in `std/core/collection/flat_hash_map.oo` goes
through a `list_set_str` that copies the key list on every write. Both are O(n)
per operation wearing the costume of an amortised structure, so reaching for
either to make the arena linear makes it slower, not faster. Reach for neither.

What the quadratic actually costs, measured on this build with `length` over a
document of *n* members, against jq answering every one in under 0.01s:

| n | object | array |
|---|---|---|
| 250 | 0.01s | <0.01s |
| 1000 | 0.19s | 0.04s |
| 3000 | 3.21s | 0.41s |

Indistinguishable from jq to about a hundred members, noticeable at 250, and
190x slower at 1000. The object is roughly seven times the array at equal size
because `jval_object` adds a second quadratic pass for the no-duplicate-name
rule. The fix is a non-copying arena, which is a language question. A "fast path"
that scans for a duplicate before rebuilding would cut the constant, leave the
asymptotics untouched, and put a silent-miscompile risk into the most-used
function in the tree; that trade has been made deliberately against.

### An operator that is the first half of an update is not an operator

jq's grammar puts `= |= += -= *= /= %=` looser than every comparison, so
`.a += 7` is one assignment. Reading `+` at the additive level and handing the
rest to `parse_primary` makes the whole filter fail as *"expected a name at
character 5"*, which points at the `7` and not at the `+` that was really the
problem. `is_update` in `parse_expr.oo` is the test: a one character operator
followed by `=` is not an operator. It has to live in both folds, because `*=`
and `/=` are eaten by the multiplication level and `+=` and `-=` by the
additive one, and the level that eats the character is the one that has to give
it back. This cost the whole feature its first run: 47 of 47 cases refused,
identically, with a build that was clean.

### The right hand side of a rewrite is a span, and the operator is inside it

Taking the text from where the left hand side ended to where the parse stopped
writes the body as `[= 7]`, because the operator sits between the two. The start
has to be the position just past the operator. Every update was refused as
unreadable before this, and the message named a character that had nothing wrong
with it.

**Carry the operator in the name, not in the body.** `+=` is `+` with a name
attached, so the body wants the bare operator; writing `+=` inside the body hands
the evaluator a second update to parse. A probe that prints the generated node
is how that was seen in seconds rather than in a binary: the node was right, the
text inside it was not, and no amount of reading the dispatch would have shown
it. **When a rewrite produces text, print the text.** The tree looked correct.

### Correct float arithmetic is reachable, and nobody had looked

This is the most expensive thing in this section to re-derive, so the evidence
is recorded here in full. **17 of the 20 unique cases where oojq and jq answer
differently are float arithmetic.** Everything else in the parity gap is one
base64 case. The shapes:

| filter | jq | oojq |
|---|---|---|
| `0.1+0.2` | `0.30000000000000004` | `0.3` |
| `0.1*0.2` | `0.020000000000000004` | `0.02` |
| `3.3/1.1` | `2.9999999999999996` | `3` |
| `0.1*0.2 > 0.02` | `true` | `false` |
| `5.5%2` | `1` | `1.5` |
| `7%3.5` | `1` | `0` |

The first four are not a rendering difference, they are a different number.
`0.1*0.2 > 0.02` being `false` where jq says `true` is a **wrong answer**, and it
is the wrong answer a jq replacement can least afford. The last two are a second
bug: jq's `%` truncates both operands to integers, and this tree does not.

**Why oojq is exact-decimal.** There is no Float in the value tree. `jval_float`
keeps the literal text the number was written with, and `num_of` in
`filter/eval/num_read.oo` reads a number as a `Num {neg, ip, fp}` — an integer
part and a fractional part held as decimal digits. That is why `0.1+0.2` is
`0.3`: the arithmetic really is exact, and jq's `0.30000000000000004` is the
artifact of binary64. **This is not a bug that was introduced; it is a
representation that was chosen because the alternative was not available, and the
choice has never been revisited.**

**Why the alternative looked unavailable.** The compiler *has* a Float and real
IEEE arithmetic — `let a: Float = 0.1; let c: Float = a * b;` compiles, and the
runtime exports `@oo_print_double(double)`. What it cannot do is put a Float
into the tree, because there is no Float-to-String:

```
ERR	llvm	float to_string needs a runtime helper
```

`emit/llvm/ll_need_tab.oo` has 149 runtime helpers. `oo_int_to_str` is one.
There is **no** `oo_double_to_str`, no `oo_ftoa`, no `oo_snprintf` wrapper, and
no way to read a double's bits. The only float output the runtime offers is
`oo_print_double`, which writes to stdout and returns nothing. So a Float can be
printed and cannot be stored, and a stored number cannot be a Float.

**Why that is not the end of it.** Int has everything IEEE needs, and it was
checked rather than assumed. All of these compile and run:

```
a & b    a | b    a ^ b    a << b    a >> b
```

and `9007199254740993 >> 31` is `4194304`, so a 53-bit significand survives a
shift intact. The crux is decimal-to-binary, because a literal has to become a
double before anything else can happen, and the usual way to get the bits is to
double the fraction until it is whole. That was built and run:

```
let mut num: Int = 1;  let mut den: Int = 10;  let mut bits: Int = 0;
while i < 60 {
    num = num * 2;
    if num >= den { bits = bits | (1 << (59 - i)); num = num - den; }
    i = i + 1;
}
```

`bits >> 32` is `26843545`, which is `0x1999999`: the implicit 1 followed by the
repeating `1001` of one tenth, which is exactly the significand of `0.1`
(`0x3FB999999999999A`). Sixty bits is more than the 53 a significand holds, so
the guard and sticky bits that round-to-nearest-even needs are both available.

**What this means, stated precisely.** Correct IEEE binary64 arithmetic, correct
rounding, and shortest-round-trip formatting are all *reachable on this
language's Int*, and that closes 17 of the 20 parity divergences. It is also a
soft-float core plus a Ryu or Grisu formatter, every operation of which has to
be exactly right, and a wrong bit is a wrong number rather than a short one.
**The same trade that ruled out the `jval_object` fast path rules this out
halfway: a half-built float core makes `0.1+0.2` *worse* than it is now, because
a wrong binary answer is a worse answer than an exact decimal one.** So the first
slice was built standing alone, with no arithmetic on top of it and nothing
importing it.

### The first float slice: `filter/eval/float/decimal_bits.oo`

`decimal_bits(text) -> Result[String, String]` returns the 16 hex digits of the
binary64 word the written number is, correctly rounded. **No value of the tree is
a double yet and nothing imports this page.** It exists to be right on its own,
which is the only way to know the arithmetic written on top of it is not the
thing that is wrong.

The method, in one line each: the fraction is **doubled from the right**, the
integer is **halved from the left**, the first 53 bits are the significand, the
54th is the guard, and everything dropped below it is the sticky; then
round-to-nearest-even. No wide integer is needed anywhere, because a digit run
always fits where 10^40 does not.

**Verified 5821 cases against an independent oracle, 0 mismatches.** The oracle
is Python's `struct` — a different implementation of the same standard, not my
own arithmetic and not a hand-written table. The corpus is deliberately built
from the shapes random generation cannot reach:

| group | count | what only it can find |
| --- | --- | --- |
| exact ties | 13 | round-half-even in both directions, including a 300-digit tie |
| exact expansion of a double | 24 | a decimal that *is* a double must come back bit for bit; up to 1074 digits |
| long digit runs | 1200 | sticky in both directions, on 55–400 digit inputs |
| random decimals | ~4400 | the full exponent range, both signs, every spelling |
| expected refusals | 439 | subnormal, overflow, and round-to-zero verdicts |

Boundaries confirmed by hand against the oracle: `2.2250738585072014e-308` →
`0010000000000000` (exactly 2^-1022, the smallest normal), `1.7976931348623157e308`
→ `7fefffffffffffff` (the largest finite), `0.1` → `3fb999999999999a`.

**Cost, measured per conversion:** 0.02 ms for `1`, `0.1`, and `1.5`; 0.4 ms for a
19-digit integer; 13 ms for `1.23e123`. The jump is not the bit extraction, it is
`num_read`: it moves a written exponent into the digits, so `1e300` becomes a
301-digit string and costs about 150 ms. The fix is known and not yet written —
keep the exponent beside the digits instead of padding it out — and it belongs to
the slice that reads a float per operation, not to this one.

#### Five traps, each of which produced a wrong answer and no error

1. **A decimal fraction doubles from the right.** Left to right, digit 2 of
   `0.25` becomes 4 and then digit 5 becomes 10, and the carry falls off the
   *middle* of the run, which is not a bit of anything. Left to right `0.25` read
   as `0.5`'s first bit, and `0.1` came out `3fb3333333333333`.
2. **The significand accumulator runs left to right.** Fed the other way it
   reads bit 1 as the least significant, and `3` answers `1.5`.
3. **IEEE negation flips bit 63; it is not the arithmetic negation of the word.**
   Negating gives the two's complement of the magnitude, which is a different
   number: `-1` came out `0xc010000000000000`, an exponent one too big.
4. **`>>` on a negative `Int` is logical here, not sign-extending.** The earlier
   note on `hex16` claimed sign extension. It was wrong, and the wrong claim is
   what made the `-1` result hard to read. Measure before believing a comment.
5. **Do not pad a zero run the digits already carry.** Prepending `lead` zeros to
   a fraction that already begins with `lead` zeros counts them twice and shifts
   the significand right by exactly `lead` bits.

`make dup-names` caught this page's `Step` and `Half` on its first gate run, both
already declared in `filter/syntax/parse_path.oo` and `filter/syntax/object_lower.oo`.
Third real catch for that gate, and the second and third arrived on new code
rather than old.

#### Arithmetic on the word: `float_word.oo` and `float_ops.oo`

A double is a dyadic rational, so **both operands and their sum and their
product are dyadic, and dyadic plus dyadic is exact.** There is no need to model
floating point at all: read each word as the exact number it stands for, use the
arithmetic that already exists on digit runs in `num_add.oo`, and round **once**
at the end through `decimal_bits`, which is the single rounding IEEE asks for.
`flt_cmp` rounds nowhere at all, because comparing exact values is comparing the
values. Fifty lines of new arithmetic, and the rest is reuse.

`flt_mul(0.1, 0.2)` is `3f947ae147ae147c`, the double `0.020000000000000004`,
and comparing that against `0.02` returns *greater* — which is the parity
divergence `0.1*0.2 > 0.02` that oojq currently answers wrongly, and the five
comparison cases were wrong answers rather than alternative renderings.

**Verified 6676 cases against Python's IEEE binary64, zero mismatches** — every
combination of a boundary set and 1669 operand pairs through `cmp`, `add`, `sub`,
and `mul`, including 852 subnormal cases and every underflow-to-zero case. The
oracle is a different implementation of the same standard, and a multiplication
that is one bit off anywhere in a 52 bit significand shows up here.

#### An exponent field of zero is two different things

`5e-324`, the smallest double there is, is **subnormal**: its exponent field is
zero and its significand is not. So is every number between it and
`2.2250738585072014e-308`. Reading `exponent field == 0` as *zero* makes every
subnormal silently become `0`, and the failure has the shape of nothing at all:

- `0 < 5e-324` answered `0` and not `-1`
- `0 + 5e-324` answered `0`
- `1 * 5e-324` answered `0`
- and `bits_text` wrote `5e-324` as `0`

A subnormal has no implicit leading one either, so its significand is the stored
52 bits alone and its exponent is the one below the smallest normal. Both
`word_read` and `bits_text` now say which of the two they are looking at.

**This is the one bug a scoped corpus cannot catch, and the corpus was scoped
deliberately.** The 1269 case check of `bits_text` filtered subnormals out
because the page refused them, and the filter meant nothing ever asked what
happened to one. The page answered them as zero anyway. The fix is not only the
code: the corpus now carries 852 subnormal cases that it used to drop, and a
differential whose oracle skips a class of input has not tested that class.

#### Refusing a result you can name is still refusing too much

A product or a sum can land below the smallest normal without being a
subnormal, and there the answer is known rather than unknown: below half of the
smallest subnormal the only nearest double is zero. `0.1 * 5e-324` is
`4.9e-325`, and its exact answer is `+0`. `rounded` now checks that boundary —
`2^-1075`, built the same way every other exact value is, and only built once
something has already been refused, because the run is not cheap — and answers
zero instead of refusing. Refusing is right for what cannot be known and wrong
for what can.

#### The same rule, one step further: `decimal_bits` refused every subnormal

The underflow fix above handles a result *below* the smallest subnormal. A result
*inside* the subnormal range was a different refusal, and it was hiding behind
the corpus. `decimal_bits` ends with

    if e2 < 0 - 1022 { return Err("decimal_bits: value is below the smallest double"); }

and a subnormal's leading one sits between `2^-1074` and `2^-1023`, so every
exponent in the whole subnormal range is below that bound and every subnormal
was refused. `5e-324 + 1e-323` is `1.5e-323` in jq and an error in oojq.

This is the **operand/result** pair of the same trap, and the corpus was scoped
to accept the refusal rather than to catch it: the `float_ops` generator marks a
subnormal *result* as `ERR` alongside NaN and Inf, so 226 of its 6676 cases
"passed" by being refused. The generator was written before the page could
answer them, and then it certified the page's own limit. A corpus that encodes a
refusal is a corpus that will never find it.

The fix is one index, one bound, and one **direction** — and the direction is
the part that is easy to get wrong in a way that produces plausible words:

- A **subnormal stores its leading one**; a normal has it implicit. So the 52
  stored significand bits are read starting **at** the leading one rather than
  one past it. The index is `j = lead + (e2 + 1074)`, the position whose exponent
  is `-1074`, and for a subnormal that is **always 1073** — the format fixes
  where `2^-1074` sits, so the formula looks like it needs a longer bit run and
  is in fact a constant.
- **The accumulator runs the other way.** Index rises as the exponent falls, so
  the subnormal field occupies `j-51 .. j` and `j` is its *least* significant
  bit. A normal's accumulator runs left to right because its leading one is
  **excluded**; a subnormal's is **included**, so it is the last bit read and
  carries weight `2^0`. Reading the window in the normal order gives the leading
  one weight `2^51`: `2^-1074` came out as `2^51` ulps, `0x8000000000000`,
  where the answer is `0x0000000000000001`, and `2^-1073` came out as plain zero
  because its one sits at `j-1`, a place outside a window that was a place out.
  The page this was written next to **already warned about it** — "walking them
  from the other end reads bit 1 as the least significant one" — and the new
  page contradicted a correct existing comment.
- The **guard is the bit under the field**, at `j+1`, not over it. A normal
  rounds on the bit past its 52nd because there is a smaller double left to
  round *to*; a subnormal is already at the bottom of the format, so the only
  question is whether the fraction underneath reaches half the last bit. The tie
  that matters is `2^52 - ½`, which round-half-even sends to `2^52` and so to
  the smallest normal — and a guard above the MSB can never see that tie.
- The bound goes from `-1022` to **`-1075`**, and stopping at `-1074` is wrong in
  the other direction. A value whose leading one is at `2^-1075` is between half
  an ulp and one ulp and rounds **up** to one ulp: `0.2 * 1.5e-323` is `3e-324`,
  which is 0.607 of an ulp, and refusing it answered `ERR` where the answer is
  `0000000000000001`. Only `2^-1076` and below is a genuine underflow, and that
  is the guard's decision rather than the bound's. The `2^-1075` tie now lands
  on the subnormal branch with `mant` zero and an even significand, so it still
  goes to zero exactly as it did when the caller owned it.
- Rounding up out of the range needs no special case: `mant == 2^52` encodes the
  same integer as the smallest normal, because `(0 << 52) | 2^52` and
  `(1 << 52) | 0` are both `0x0010000000000000`.

All three of the bound, the direction and the guard were wrong in the first
version, and each was caught by a case whose answer is known by hand rather than
by the corpus. **A run of 1056 targeted cases found 8 failures after the
direction fix and 0 would have been obvious to a reader of the neighbouring
page.** The generalisation: when a new page sits next to an existing one that
already documents a trap, the existing trap is the first hypothesis, and the
first thing to check is whether the new code contradicts it.

#### A fixed digit count is not a rounding, and the measurement said so

Division is the one float operation that is not exact on dyadic operands, so it
is the only place a digit count has to be justified rather than assumed. The
question was whether 17 significant digits of the quotient is enough on its own,
or whether a boundary check is required. Measured over 5698 quotients whose
answer is finite, against CPython's correctly rounded `Fraction -> float`:

| digits | plain truncation wrong | boundary check needed | bracket + exact fallback wrong |
|---|---|---|---|
| 17 | 630 (11.1%) | 23.2% | 295 |
| 18 | 66 (1.2%) | 2.4% | 27 |
| 19 | 5 | 0.21% | 1 |
| **20** | **1** | **0.05%** | **0** |
| 21–25 | 1 | ~0.04% | 0 |

The first estimate for this said "17 digits, with a tie roughly 1 in 2,200". Both
halves of that were wrong. 17 digits is wrong on 11% of quotients, not 0.05%,
because the truncation error itself — up to a whole decimal ulp, which is most
of a binary ulp — dwarfs the exact-tie cases that estimate was reaching for. And
**no digit count alone is sufficient at any width tested**: plain truncation is
still wrong on 1 case at 20 digits, and that case is `5e-324 / 2`, which needs
the subnormal fix above as well.

The construction that is correct is a bracket, and it is short:

1. Truncate the exact quotient to 20 significant digits, giving `q`.
2. `d1 = round(q)` and `d2 = round(q + 1ulp_dec)`. If `d1 == d2`, that is a
   **proof**, not a guess: round-to-nearest-even is monotone, and the exact
   quotient lies in `[q, q + 1ulp_dec]`, so it rounds to `d1` too.
3. Only when `d1 != d2` fall back to comparing `a` against `b * midpoint(d1,d2)`
   exactly, and take the side it falls on, ties to even. This fires on 3 of
   5698 at 20 digits.

Step 3 needs no new arithmetic and no wide integer, because both operands are
dyadic and so is their product: `b * midpoint` is exactly representable as a
digit run, so the whole comparison is one `dd_mul` and one `num_cmp`, both
already verified on thousands of cases.

**The measured lesson is about the shape of the evidence, not the digit count.**
A bracket whose two ends round to the same double is a proof; anything that
depends on how unlikely a near-tie is is a guess wearing a proof's clothes. The
`fires` column is the honest measure of the guess and the `wrongB` column is the
one that decides the design.

#### A convention error in the measurement is indistinguishable from a bad design

The first two runs of that table were nonsense and both looked plausible.
`1.0 / 1.0` came out as `10`, and then as `0.1`, because `value_of` read the
place value of the last digit as `10^dp` instead of `10^(dp - len(run))` — the
same `dp`-versus-run-length confusion that `point_back` documents and that
`from_exact` in `float_ops` already gets right. The second was a `dp` search that
aimed at the wrong window, so it computed the number of digits *after* the point
instead of before it. The first reported method A wrong on 712 of 5698; the
corrected answer is 630. Both times the tell was in the first line of output:
`1/1` is not a hard case, and a table where the trivial inputs are wrong is a
table about the harness.

The generalisation: `Fraction` normalises with a `gcd` on every operation, which
made the first run take twenty minutes, and a `10 ** -3` silently returns a
`float` in Python, which is how an integer-only comparison turned into a float
one and raised `OverflowError` on a 300-digit number. Neither was the design
question. Write the sanity cases down and run them first.

#### jq has no infinity, and it clamps instead of overflowing

Measured against jq 1.8.1, and all three rules contradicted the oracle this repo
had been using, which was written from IEEE rather than from jq:

| expression | jq |
|---|---|
| `1e308 * 10` | `1.7976931348623157e+308` |
| `1e308 + 1e308` | `1.7976931348623157e+308` |
| `1e308 / 1e-10` | `1.7976931348623157e+308` |
| `1 / 1e-320` | `1.7976931348623157e+308` |
| `1e-320 * 1e-10` | `0` |
| `1 / 0` | error, see below |

**The clamp is measured on single operations, and a chain does not follow it.**
Every expression in that table overflows in one step. jq's actual behaviour is to
carry an infinity through the middle of an expression and clamp it only when the
value is *printed*, so `1e308 * 10 / 1e10`, `1e308 * 10 / 1e300` and
`1e308 * 10 / 1` all print `1.7976931348623157e+308` — the divisor does not matter,
because the multiply was already infinite. oojq clamps at each operator instead, so
the same three print `1.7976931348623157e+298`, `179769313.48623157` and
`1.7976931348623157e+308`. This is a real divergence and it is left open: matching
it means carrying an infinity between operators, which is the one thing this value
tree has no way to hold, and reintroducing one to fix a rare overflow chain is a
worse trade than the chain. It is named here so it is not mistaken for a rounding
slip. **The lesson is about the measurement, not the case:** "jq clamps" was taken
from single-step expressions, and a rule read off one shape of expression is not
the rule until it has been tried on another.

**Overflow clamps to the largest double**, for every operator, not only
division. There is no `Inf` in jq's value tree and no `NaN` either, so a page
that produces one is producing a value jq cannot produce, and a corpus that
expects `Inf` is encoding IEEE rather than jq. The `float_ops` generator marked
overflow results `ERR` beside NaN, which was wrong in a second way: 42 of its
6676 cases overflow, and jq answers every one of them with the largest double.

**Division by zero is refused**, with a fixed sentence:

    number (A) and number (B) cannot be divided because the divisor is zero

`A` and `B` are the operands **as they were written**, not re-rendered: `1.0`
stays `1.0` with its point, `1e300` becomes `1E+300` in the upper case spelling
the literal path uses, and `-0.0` keeps its minus. jq keeps the original text of
a number, so this message echoes source text. `-0/0` prints `number (0)` and not
`number (-0)`, because the minus is a runtime negation in jq's grammar and the
literal behind it is `0`.

**Underflow keeps the sign.** `-1e-320 / 1e10` is `-0` and not `0`, and
`-5e-324 * 0.5` is `-0`. This is the opposite of the `2^-1075` tie, which
round-half-even sends to `+0`: a tie has no sign to preserve, because the
exact value is positive, whereas an underflow that is not a tie is a negative
quantity that rounded to nothing.

So the value set is smaller than IEEE's, and the three places it is smaller are
all places a refusal or a clamp belongs rather than a word.

#### JSON has no signed zero, and a comparator that loses the sign invents a bug

Checking the corrected division oracle against jq over 200 sampled cases turned
up one mismatch: an underflowed quotient where jq said `0000000000000000` and the
oracle said `8000000000000000`. Run directly, jq prints `-0` and Python gives
`-0.0`. **They agreed and the comparator was wrong**: `json.loads("-0")`
returns the *integer* `0`, because JSON has no negative zero, and `float(0)` is
`+0.0`. The sign has to be read off the text before parsing.

That is the third time in one sitting that the harness was the bug, after `1/1`
coming out as `10` and a `[1]` jq program that constructed an array instead of
indexing one. All three produced a clean, confident, wrong report. The defence
is the same each time and it is not subtle: **when a measurement disagrees with
the oracle, print the raw values before believing either.** Two of these would
have been filed as page bugs and "fixed" in the wrong direction.

#### A fix in one page silently broke another, and the direction of the blame matters

The overflow clamp described above went into `decimal_bits` and was correct
there. It then broke `bits_text`, three pages away, with no error and no
warning: **the largest double came out as `2e+308`.**

`bits_text` finds the shortest decimal that reads back as the same double by
trying one, two, three… digits and keeping the first that round trips. Each
candidate is checked by asking `decimal_bits` what word it produces. The
one-digit candidate for the largest double is `2e308`, which is *past the top*,
and the old code skipped it because `decimal_bits` refused. The page says so in
a comment: *"a candidate that will not fit is not a candidate."*

The clamp removed the refusal. `decimal_bits("2e308")` now answers
`7fefffffffffffff`, which is the very word the search is looking for, so the
search accepted "2" and published the largest double as `2e+308` — a number that
is not a double and not a rendering of one.

The generalisation is about **what a shared helper is being asked**. Arithmetic
wants "what double does this round to", where clamping is right and refusing is
wrong. The round trip wants "is this decimal the correctly rounded
representation of this double", where clamping is *wrong*, because a value that
clamps into range is not a representation of anything. One question, two
answers, and a helper that can only give one of them.

The fix keeps the helper and makes the caller ask the second question directly:
`bits_text` compares each candidate against `word_num("7fefffffffffffff")` and
skips anything above it before probing. Taking the bound from a **word** rather
than a 300 digit decimal literal matters more than it looks — a mistyped
constant in a comparison is a bug that passes every test until the day it
matters.

**The blame is worth being precise about.** The existing comment described the
correct behaviour for the code as it stood; the new change made the comment
false. Neither the comment nor the code was wrong on its own. What is worth
remembering is that a helper shared across pages carries an *implicit contract*
about what question it answers, and changing its answer changes every caller
that depended on the old one without any of them changing.

#### Subnormals in `bits_text`, and a "fix" that was the bug

`bits_text` refused every subnormal by name, and said so in a comment admitting
why nothing had caught it: *"the corpus that checked this page left subnormals
out."* The extended corpus is 1,269 original cases plus 667 subnormals, and it
finds that immediately — 669 of 1,936 wrong, every new one.

The obvious fix is to hand `exact_digits` a subnormal's own exponent, `2^-1074`.
**That is the bug.** `exact_digits` takes a significand and returns
`significand * 2^(exponent - 52)`, and `word_read` already gives a subnormal
the exponent `-1022` precisely so the shared call is correct:
`w.m * 2^(-1022-52)` is `w.m * 2^-1074`. Passing `-1074` gives a value `2^52`
too small, no candidate round trips, and the page publishes the whole 300 digit
expansion as the "shortest" form. Reverting to the original one-line call and
removing only the refusal is the whole fix.

So the subnormal needed **no special case at all** once it stopped being
refused. Every one of the three subnormal bugs this stretch — the bound, the
accumulator direction, and now the exponent — came from believing a subnormal
differs from a normal in more places than it does, and each was caught by
checking a case whose answer is known by hand.

#### An Int node has an empty `sval`, and every kind does not carry its value the same way

Wiring the float pages into the operators cost one line each and broke **20 of
669** behaviour tests on the first run. Sixteen were mine and four were stale, and
the sixteen had one cause:

`JVal` has `kind`, `bval`, `ival`, `sval`, `keys`, and `kids`, and **the two
number kinds do not keep their value in the same field.** A float keeps its
written text in `sval`; an Int keeps its value in `ival` and leaves `sval`
**empty**. So the obvious conversion — `decimal_bits(v.sval)` — turns a whole
number into the empty string, which reads back as zero:

    1.5 * 2   came to 0        (2 became 0)
    1.5 + 1   came to 1.5      (1 became 0, so the left side survived)
    -1.5 * 2  came to -0

`1.5 + 1` returning `1.5` is the tell. An operator that returns its left
operand unchanged is usually a discarded operand, not an arithmetic identity.

The generalisation: **a tagged value's fields are only populated for the kinds
that use them, and reading the wrong one is not an error, it is a default.**
Zero, the empty string, and the empty list are all valid values, so a field that
was never written reads as something that looks fine. Check what a *missing*
field reads as before trusting it, and remember that `num_of` already exists
precisely to paper over this — the new page should have used it.

#### A test suite can assert a known divergence and stay green forever

The other four failures were tests that had **documented the wrongness as
intended behaviour**, in their own names:

    "0.1 * 0.2 is 0.02 here and 0.020000000000000004 in jq"
    "and a square of nine digits is exact, where jq rounds it"
    "0.1 + 0.05 is 0.15 here and 0.15000000000000002 in jq"

So `num_mul` was "exact", the test said so, and 669/669 was green — overclaim
promoted to a specification. The arithmetic was **more accurate than jq and
wrong for the purpose**, and no test could ever have caught that, because the
test was written to agree with the bug.

A test that names the divergence it is allowing is a test that will keep
allowing it. The fix is to delete the "here and X in jq" clause rather than
reword it, so the next person to read the line has to go and measure. The
replacement lines now say what the answer **is**, and why.

**This is the one place where "all tests pass" and "the behaviour is right" are
the same claim, which is why they usually are not.** Everything else this stretch
changed had a differential that could disagree; these four had only themselves.

#### A deliberate divergence that was right to make and right to give back

`%` was the one operator oojq answered *differently* rather than more exactly,
and it was measured, not guessed. jq's `%` is not `fmod` and not a remainder:

| | jq | `fmod` | oojq was |
|---|---|---|---|
| `5.5%2` | 1 | 1.5 | 1.5 |
| `7%3.5` | 1 | 0 | 0 |
| `2.5%1` | 0 | 0.5 | 0.5 |
| `1%0.5` | refused | 0 | 0 |
| `5.5%-2` | 1 | 1.5 | 1.5 |
| `-5.5%2` | -1 | -1.5 | -1.5 |

It truncates **both** operands toward zero, then takes an integer remainder with
the sign of the left, and it refuses a divisor that truncates to zero. The
previous session probed this 21 times, concluded it was a rule and not an
accident, wrote the true remainder anyway on the grounds that `7 = 2*3.5 + 1` is
false, and named the divergence in the README as a feature.

That reasoning was sound and the conclusion was wrong. The arithmetic complaint
is real — jq's `%` genuinely fails `a = q*b + r` — but it is not a float case.
The float work this round moved toward jq because **jq follows the hardware
there**, and the hardware is what every other program on the machine does. jq's
`%` follows nothing: it is a jq-specific choice, measured and deliberate, and a
script that migrates from jq depends on it exactly as much as it depends on
`0.1+0.2`.

The deciding argument is not which answer is better. It is that **the two differ
and nothing errors**. `5.5 % 2` returning 1.5 where the tool everywhere else
reproduces jq's 1 is a silent behaviour change on a non-integer operand. A
replacement whose value proposition is compatibility cannot do that for a
three-line gain, however good the arithmetic is.

**The generalisation: "more exact than jq" is only ever a virtue when jq is
being inexact by accident.** Both the float cases and this one were argued on
that phrase. The floats were wrong because jq matches IEEE and its users'
hardware; `%` was wrong because it does not, and nobody but jq does it that way.
Before claiming a divergence is an improvement, ask which of those two it is.

The fix keeps the sign field, so the left operand is still the sign of the
answer, and drops the fraction rather than flooring it — `-5.5 % 2` is `-1` and
not `0`. The two definitions agree exactly where the operands are whole, which
is the only place the identity `a = q*b + r` survives either way.

#### Two arena-hungry processes at once is worse than one slow one

Running the `float_ops` and `bits_text` differentials side by side corrupted
the first one: output that was locally one line out of step, re-aligning
further along, every "answer" a plausible looking word belonging to a different
case. Each chunk was clean in isolation. The cause is the same no-reclamation
property as the NUL cliff — two processes each holding an arena that only grows,
against a memory budget, and one of them killed part way through a chunk. **Run
these one at a time.** It is a slow way to learn that a harness failure and a
page failure can look nothing alike.

#### Re-running the differentials

The harnesses are build-time artifacts, not repo files: the oracle is Python and
the file law forbids `.py` here. Four probe directories hold them — `/tmp/dbprobe`
for `decimal_bits`, `/tmp/edprobe` for `exact_digits`, `/tmp/btprobe` for
`bits_text`, `/tmp/opsprobe` for `float_ops` — each a `main.oo` importing only
`ipc/read_source.oo` and the page under test, a `gen.py` that writes
`cases.txt` and `expected.txt`, and a `cmp.py` that compares, treating a refusal
as a refusal whatever message it carries. The probe builds in about three minutes
against the project root (imports resolve from the working directory, not from
the probe's own folder) against fifteen for the full tree.

### jq has two ways to write a double, and only one of them is ours

Measured, not assumed, and the two disagree in ways that would have shipped a
formatter that is wrong on every exponent:

| filter | literal path | computed path |
| --- | --- | --- |
| `1.0` | `1.0` | — |
| `1.0*1` | — | `1` |
| `1e15` | `1E+15` | `1000000000000000` |
| `1e16` | `1E+16` | `1e+16` |
| `1e-5` | `0.00001` | `1e-05` |
| `1e-7` | `1E-7` | `1e-07` |
| `-0.0` | `-0.0` | `-0` |

A number **parsed** from text keeps a point and an uppercase, unpadded exponent. A
number **computed** loses the point when it is whole and takes a lower case
exponent, always signed, never narrower than two digits. The parity corpus is
made of expressions, so **the computed path is the target**; the literal path is
what oojq's "keep the written text" behaviour matches, and keeping it is correct
for input that is passed through untouched.

**The computed rule is not a position threshold, and getting that wrong is the
trap.** Scientific notation is used when the number is below `1e-4`, or when the
full form would end in **sixteen or more zeros** after the significant digits:

- `1e+16` is an exponent, `1.1e+16` is not, and both sit at the same place on the
  number line. The first is one digit with sixteen zeros behind it; the second
  has fifteen.
- `1e15` is written out, `1e+17` is not, and both are a single digit.
- `12345678901234568` is written out: seventeen digits, no zeros at all.

So the test is `dp < -3 || dp - ndigits >= 16`, where `dp` counts the digits
before the point. A threshold on `dp` alone cannot tell `1e16` from
`1.1e16`, and that is exactly the assumption a standard would suggest.

#### The harness can be the bug

`exact_digits` first came back 591 wrong out of 634, and every one of them had a
negative exponent. The cause was the probe: its digit scanner returned `0` for
`-`, so `4503599627370496 -1` reached the page as `e2 = 1`, and the page
faithfully and correctly answered `2 1` for the value it was actually handed.
Nothing about the page was wrong. The cross-tabulation that found it was worth
more than any amount of reading the code: the `k >= 0` branch was 568 for 568
and the `k < 0` branch was almost all wrong, and a branch that is perfect on one
side of a condition and broken on the other is a harness bug until proven
otherwise. **After a harness says a page is broken, check what the harness
actually passed it.**

#### A long run degrades, and that is the arena

The formatter allocates a fresh digit run for every step of every expansion and
nothing is ever freed. Run the 1269 case corpus in one process and after about
130 cases a line comes back as NUL bytes and every answer after it is shifted by
one; the same case in isolation is correct. Run it in chunks of sixty and the
whole corpus is clean. This is the same no-reclamation property already recorded
for the value arena, showing up as a correctness cliff rather than a slowdown,
and it is the strongest argument yet for keeping a growable buffer out of reach
of anything on a hot path.

#### The other half of the round trip: `exact_digits.oo` and `bits_text.oo`

Every double is a dyadic rational, so its decimal value is exact and finite, and
`exact_digits` writes it out with no rounding at all: a digit run times a power of
five, a digit run times a digit run, carry by hand. The widest value in range is
767 digits across, so this is big arithmetic in strings, and `Int` is no help
because 63 bits is not 767 digits.

`bits_text` then puts the value back together. It takes the word apart, expands
it exactly, and **drops digits one at a time while the word still reads back the
same**, testing each candidate by handing it to `decimal_bits` and asking whether
the word that comes out is the word that went in. The first candidate that
survives is the shortest, by construction, and because the two ends check each
other neither has to be trusted.

**Verified 1269 cases byte-identical to jq's computed path**, and separately
checked that jq's own output is shortest-round-trip in 1269 of 1269 — it never
prints a digit more than it needs, so the target is exactly reachable rather than
approximately reachable. `0.1` comes back `0.1` and not the 55 digit expansion it
actually is; `-0` stays `-0`; `1e+16`, `1e-05`, and `12345678901234568` all land
where jq puts them.

Three more traps, all of which produced wrong answers with no error:

1. **The round trip probe has to carry the sign.** A negative word checked
   against a positive reading of itself never matches, so `-0.1` fell through
   the whole search and printed its own expansion. Every positive case passed and
   every negative case failed, which is the shape to look for.
2. **A candidate that does not fit is not a candidate.** Rounding the largest
   double to one digit gives 2e308, which `decimal_bits` refuses; treating that
   refusal as fatal threw away the sixteen shorter answers that were fine.
3. **There is no short cut through the search.** Seventeen digits is how many a
   double can be pinned *by*, not how many it needs, so an expansion of exactly
   seventeen may still have a sixteen digit answer below it. `794379958272090.75`
   is the exact value of the double jq writes `794379958272090.8`, and taking
   seventeen as final printed the exact value instead of the number.



`finish_member` moved a member walk's finishing step to its own page. It took a
`List[Int]` of kept members and handed them back in the result struct. The build
was clean. `oodac check` was clean. `line-cap` and `density` were clean. And
`2 | select(.>1)` answered **nothing** where jq answers `2`.

Nine assertions failed: `select`, `map`, `collect`, and all five by-key modes.
Every mode that hands a list out to a callee on another page and reads it back
got an empty list; every mode that does not was unaffected. The extracted page
was correct on inspection and there were no duplicate names. It is a miscompile,
and the worst kind, because nothing reports it.

The rule already in this file — *an edit that has not been measured is not
finished* — is what was skipped. I measured the feature built on top of the
refactor and never measured the refactor. `make test` is two minutes and a
refactor is a behavioural change like any other: it moved a list across a page
boundary, which is exactly the operation the language makes moves for.

So: **run `make test` after a refactor, before building anything on top of it.**
Structural gates are not behavioural verification, and the compiler agreeing is
not evidence.

### A call that reads its argument as a filter has to be split per value first

`run_builtin` dispatched a `func` node before the per-value split, and its tail
evaluated the argument over `input[0]` alone. So `1,2 | {a: 1}` built one object
where jq builds two. It was latent almost by accident: the only builtins that
take a filter argument were object construction and `getpath`, and `getpath`
happened to walk the whole stream itself.

The fix is one line, and its position is the whole content: the split goes
**after** the member-builtin and routed branches, never before. A member builtin
such as `map` consumes the whole stream itself, and splitting it would turn
`1,2 | map(.)` from one error into two.

**A builtin that reads its argument over one value is a per-value step, and the
split belongs on the path that says so.** A dispatch order that happens to work
because only one builtin reaches a path is a coincidence, not a design.

### The way past a full page is a parse-time rewrite, not a free line

`filter/run/eval_run.oo` is the one page holding `eval_text`, so anything that
needs to read a sub-filter has to be dispatched from there, and it is at its
ceiling. Three attempts at object construction made the arithmetic plain: a
driver loop in a new page was a **cycle** (the page the hub imports must not need
`eval_text`, and the language has no function values to break it with), a driver
loop in the hub did not fit even after two extractions, and only a parse-time
rewrite did.

`{a: X, b: Y}` is not object construction as far as the run is concerned. It is a
call over the body `[[X], ["a"], [Y], ["b"]]`, and a collect **already** gathers a
filter's answers, so the product is a multiply over lists that are paid for
elsewhere. One hub line, not twenty-nine. `with_entries(f)` is the same shape of
answer one layer over: it is `to_entries | map(f) | from_entries`, which was
checked against jq on a value update, a key update, and a `select` before a line
of it was written.

**So before asking for room on a full page, ask whether the feature is a
different spelling of steps that already exist.** `limit`, `first`, `last`,
object construction, and now `with_entries` were all free. The ones that are not
— `setpath`, path mode, `as $x`, `try` — are not lowerable because they need
something to happen *while values are read*, and that is the honest dividing
line between a rewrite and a real feature.

### A builtin that only exists as a rewrite still exists

`limit` written with no argument answered `unknown builtin "limit"`, which is
false: `limit` is a builtin this build has, and the thing the reader got wrong
was the missing argument. It is the same shape as the `def` story below, where a
reserved word was answered *unknown builtin "def"; did you mean "del"?* — a
suggestion pointing at a name with one letter in common. `with_entries` would
have inherited the same lie.

A name that is lowered into a rewrite is still a name, so the bare form says what
it wants: `"with_entries" needs a filter argument, as in with_entries(.items[])`.
**"Unknown builtin" is only honest for a name this build has never heard of.**

### A page at its ceiling refuses a feature; it does not squeeze one in

`limit(n; f)` is `[f][0:n][]`, and every part is already paid for: a collect walks
the body, `n_slice(0, n, …)` takes a run, `n_iterate` puts the values back on the
stream. It was written into `pick_by_index` beside `first` and `last`, sharing
their collect, and the page went to 262 against a ceiling of 256. It was reverted.

The tempting move is to shorten a comment or inline a two-line helper to make
room. That is the wrong trade: a page that only fits by deleting its reasoning
is a page whose reasoning is the first thing to go under the next deadline, and
the feature it bought is one refactor away from being lost. The design is written
into the comment above `pick_by_index` instead, so it survives the revert.

`filter/syntax/` has one free page. Spending it on a lifted copy of this rewrite
is a real refactor and belongs in its own increment, not beside three bug fixes.
`parse_span.oo` was the other candidate home for `range_parts` and had eight free
lines against the sixteen it needs, which is how the question got asked at all.

### A function that is written but never called is worse than no function

`reserved_word` in `parse_prim.oo` refused all nine of jq's reserved words by
name, and nothing called it. The page *looked* like it handled `def`, `as`,
`reduce`, and the rest, and a filter beginning with `def` was actually answered
`unknown builtin "def"; did you mean "del"?` — the suggestion mechanism
pointing a reader at a builtin with one letter in common, on the one input where
the reader had named a language construct. The message was not merely vaguer than
intended; it was actively wrong in the direction that costs the most time.

The scan that finds this is one line, and it should be run after adding any
function:

```
for f in $(grep -oE '^(pub )?fn [a-z_0-9]+' PAGE.oo | sed 's/pub //;s/fn //'); do \
  printf '%-24s %s\n' "$f" "$(grep -rho "\b$f\b" --include=*.oo . | wc -l)"; done
```

A count of 1 is the definition and nothing else: the function is dead. A count of
2 is a definition and a single call, which is legal but worth a look. This is the
same scan as the duplicate-name one in the same breath, and it catches the
opposite failure: a name that collides, and a name that is never reached.

### Two names, one sentence, no test

Three assertions shared a name when the dead-test gate was written, and each name
was a continuation of the one before it: "and not above it", "and the same the
other way round", "an empty stream collects to nothing". Continuations are
writeable only next to their neighbour, so they cannot be reordered, cannot be
read in a failure log on their own, and cannot be deleted without deciding which
of the pair was the real one. `make dead-tests` now fails on a shared name.

There is still no mechanism for retiring a test that no longer protects anything,
and no record of which page an assertion belongs to, so "what breaks if this page
goes away" cannot be answered. That is the open half of this problem.

### 6a. Traps that cost a build each

These are not in the manual. Each one compiled cleanly and then produced a
plausible wrong answer, so each was found by a differential run against real
`jq` rather than by reading the code.

- **`filter/run/eval_run.oo` is a hub that cannot be decomposed, and that is the
  bottleneck for most of what jq still does.** `eval_text` and `eval_filter` are
  mutually recursive; every other function on the page (`fold`, `eval_bin`,
  `eval_if`, `guarded`, `gather`, `per_member`, `run_builtin`) calls one or both.
  So moving any of them to a new page would need the new page to import
  `eval_run.oo` while `eval_run.oo` imports it, and mutual imports are rejected.
  The page sits at 253 of its 256 lines, so **a feature that has to evaluate a
  sub-filter cannot be added at all** until the page shrinks. Blocked this way:
  object construction `{a: f}`, `as $x`, `walk`, `limit`, `with_entries`,
  `recurse(f)`, and the per-value split in `gather`. A feature that needs only
  `doc` and node indices — `getpath`, `@json`, `first`/`last` emptiness — costs
  zero hub lines if you give the parser a spare node field to mark it and honour
  that field in `eval_join.oo`. Two node fields are already spare on `ANode`:
  `name` is unused on `index` and `slice` nodes, and `t1`/`t2` are unused
  outside `ifthen`.
- **The way out is to move the hub's leaf routing into `filter/eval/`, not to
  raise the cap.** `run_builtin` used to answer `paths`, `leaf_paths`, `sort`,
  `unique`, `range`, and the no-argument case itself. None of those evaluates a
  filter, so all of them moved to `route_builtin` in `filter/eval/eval_builtin.oo`
  behind an `is_routed` predicate, and the hub kept one line. That page was
  already importing across into `filter/run/` (for `eval_suggest.oo`), and
  `eval_sort.oo` and `eval_path.oo` are leaves, so no import cycle appeared.
  Moving code *out* of the hub is the only decomposition that works; squeezing
  its comments is not, and the cap does not need to move.
- **Duplicate function names across pages silently mis-dispatch.** Two pages may
  each `pub fn` the same name with different signatures; the linker picks one
  and calls never reach the other. Run this after adding any page:
  `grep -rhoE '^(pub )?fn [a-z_0-9]+' --include=*.oo . | sed 's/pub //;s/fn //' | sort | uniq -d`
- **Reading the same struct field twice returns empty the second time.** A
  `Result[SRes, String]` binding, read once to build a list and again to pass it
  on, hands the second read a moved-from empty list. This is how every
  argument-taking builtin (`join`, `has`, `startswith`, `range`) came to print
  nothing at all: exit 1, no message. Bind each field to a local exactly once.
- **An argument that was just evaluated lives in the grown arena, not the one
  you started with.** Pass the `SRes.doc` that came back from the evaluation.
- **A step that mints a value must hand back the grown arena.** `bool_result`
  pushes onto the document and returns a new one, so a caller that keeps the
  document it started with returns an index into an arena nobody else can see.
  `and` and `or` did exactly this and silently produced no values at all: exit
  0, nothing printed. Thread it as `live = v.doc` the way `walk` does.
- **A nested call in an argument list is not reliably lowered.** Written as
  `bool_result(doc, both(a, b))` the emitter took the inner call for a plain
  value. Binding it to a local first is the house rule everywhere. Note that
  this was *not* the cause of the empty `and`/`or` above, which was the arena;
  both rules are real and both were fixed in the same edit, so do not assume one
  explains the other.
- **`chars_len` counts characters and `byte_at` indexes bytes.** Looping
  `while i < chars_len(s)` while reading `byte_at(s, i)` walks past the end of a
  multi-byte string and silently drops its trailing bytes. The renderer did
  this, so `"héllo"` printed as `"h\\u00c3\\u00a9ll"`. Use `char_at` when walking
  characters and `byte_at` only when you have a byte count.
- **`at` is a reserved builtin typed `Int`**, so `let mut at: Cur` does not
  compile. `where` and other language keywords cannot be match bindings; a
  `Ok(where) =>` arm fails in the LLVM emitter with an unrelated message.
- **A struct field read can resolve to a same-named local.** In a page holding
  `let b: Result[...]`, the expression `n.b` returns the local. Bind every
  `ANode` field to a named local before use.
- **A `Result` built inside the `Ok` arm of a `match` on another `Result` fails to
  emit.** `setpath`'s `grow_from_null` ends with `return Ok(pad_array(...))` where
  `pad_array` also returned a `Result`, from inside `Ok(z) =>`, and the build died
  at the LLVM stage with `ERR llvm Ok kind` after a dump of debug info for the
  enclosing scope. `check` is clean; only `build` sees it. The fix is to make the
  helper infallible (`-> SRes`) and refuse the negative case at the call site, so
  no `Result` is constructed inside the arm. This is the third shape in this
  family, after a `Result` carrying a locally declared struct that `match` would
  not destructure, and a list handed back through a result struct from another
  page arriving empty. The lesson across all three: **inside a match arm on a
  `Result`, return a value rather than build another `Result`.**
- **A `Result` payload must stay narrow (three words) across a page return.**
  `Tok` as `{text, cur}` lost a leading byte on return from another page; it is
  `{text: String, pos: Int}` now, and callers rebuild the `Cur`.
- **The parser has to find where a body ends, never parse it.** A bracketed body
  is kept as raw text in the node and parsed when the evaluator reaches it.
  That is what lets the parser and the evaluator be separate pages at all.
- **The evaluator's whole recursive core must live in one page.** `eval_text`
  and `eval_filter` call each other and everything else calls back into them, so
  `filter/run/eval_run.oo` sits at the 256-line ceiling. Plan additions to it as
  trims, or they will not fit.
- **`std/fs/os/fs.oo` will not lex with the installed `oodac`.** It contains
  `→` (U+2192) in five comments and the lexer rejects non-ASCII in comments. The
  file is committed and clean, so this is pre-existing upstream. oojq calls the
  sealed `oo_path_exists` and `oo_fs_is_dir` builtins directly instead, which
  keeps the capability check the compiler emits.
- **Never run `filter_eval` over a document you assembled by hand.** It seeds
  the run from `in_doc.root`, and only `parse_document` sets a root that means
  anything. A `jdoc_new()` with values pushed onto it answers with nothing at
  all: no stdout, no stderr, exit 1, and no message anywhere. Every MCP tool
  call that did this died silently, while the same filter on the command line
  was fine. Build a document with `parse_document`, or hand it the text.
- **Do not "fix" a silent death by binding the return value first.** That is a
  real habit here, and it cost an hour on the bug above: `return v.sval;` and
  `return some_call(x);` appear 100-odd times across pages that work, including
  `render/render_value.oo:22` which ships in the `@text` path. Changing them
  changed nothing and the process kept dying. Bisect on what the failing cases
  *share* — here, the hand built document, not the return style.
- **`std/core/text/regex.oo` is only safe for `test`.** `regex_is_match` hands
  the whole string to the NFA and is correct — including substring and `|`
  matching — so `test` works. Everything else is built on `match_pattern_first`,
  whose inner cursor runs to `t_len + 1` and calls `str_slice` one past the end:
  `"abc" | sub("z"; "y")` reads off the buffer and dies on SIGSEGV, exit 139.
  `splits` and `sub`/`gsub` are therefore **refused by name**, not implemented.
  The NFA also has no character class, so `splits("[0-9]")` would be a wrong
  answer rather than an error. Do not "fix" this by switching to a different std
  entry point — there is no safe one; the defect is in the shared match search.
  `split` (literal) and `test` cover the safe subset.
- **An unused import is a hard type error, and a page can carry a dead one for
  months.** `oodac check` reports `unused import 'x'` as a failure. Deleting the
  only caller of a re-exported helper elsewhere in the tree can surface an import
  that was already dead, which reads as a regression you did not cause.
- **The unused-import check does not count type-only use, so trust it last.**
  `filter/eval/eval_leaf.oo` uses `Num` in a `Result[Num, String]` and nothing
  else from its `eval_num.oo` import, and oodac called that import unused — but
  removing it made `Num` undefined and the whole tree fail. Import the page that
  *declares* the type you use, not one that re-exports it: `num_read.oo` declares
  `type Num`, so `eval_leaf.oo` imports `num_read.oo` and the check is satisfied
  honestly. Never delete an import on the strength of that diagnostic alone;
  delete it and then re-check the file, not just the file that reported it.
- **`make check` checks one file at a time and used to stop at the first failure
  without naming it**, so a single dead import cost a two-and-a-half minute round
  trip to identify. It now prints the file, and prints the compiler's own message
  too, because the name alone did not say *which* import. When a new page is likely
  to have one, loop the compiler over every `*.oo` and print all failures rather than
  stopping, because the first error is rarely the only one.
- **`//` is not "run the right side over the falsy values on the left".** That is
  what it was implemented as, and it is wrong twice: the right side runs over the
  **original input**, so `.a // .b` on `{"a":null,"b":1}` is `1` and not `null`; and
  the right side must not be evaluated at all when the left was truthy, so
  `1 // error("x")` is `1` in jq. Both fall out of one rule in `side_input`: feed the
  right side an **empty list** when the left had a truthy value, and the original
  input otherwise. An empty list is what makes the right side never run.
- **Returning a bare value where a `Result` is declared compiles, and lies.**
  `gather` is declared `Result[SRes, String]`. Writing `return empty_array_over(...)`
  where that call returns `SRes` type-checks fine, and every pipe after an empty
  collect then silently returned the *left* side: `[] | type` printed `[]` instead
  of `"array"`, and `[1] | type` still worked, so it read as a parser bug. The
  same call wrapped as `return Ok(empty_array_over(...))` was correct. **Wrap an
  `SRes` in `Ok` when the enclosing function returns a `Result`.** Everywhere
  else in this tree a returned `SRes` is written `return Ok(...)`, and that is
  not a style choice, it is load-bearing.
- **`sqrt` answers squares and refuses the rest. Do not "fix" that by
  rounding.** jq answers `2|sqrt` with `1.4142135623730951`, the shortest text
  that names the IEEE double it computed; the exact root of 2 has no finite
  decimal spelling, and matching jq would mean producing that double, which this
  tree has no way to hold. A rounded root printed as though it were exact is the
  confident wrong answer everything else here refuses to give, so `num_sqrt`
  returns an error for a non-square and `sqrt_over` turns it into a refusal that
  names the reason. The exact half is real and tested: a whole or decimal square
  gets its root, `-4` gets jq's `null`, and a whole root prints as a whole.
- **A builtin that reads index zero of its input must ask whether the input is
  empty first.** `//` reaches `run_builtin` with an empty input whenever the left
  was truthy, and `list_get(input, 0)` on that is an out-of-bounds abort — not an
  error message, a dead process. This is the one failure mode in the tree that
  shows up as a missing newline and nothing else.
- **Adding a by-value call to `eval_run.oo` can make oodac report `use after move`
  on untouched code, at an earlier line, and none of the obvious repairs clear
  it.** Six builds went into this, so do not start without reading it. The page
  passes a `JDoc` and a `List[Int]` into calls by value in several places and is
  only correct because the other value gets rebound; `eval_if` and `gather` each
  hand a parameter straight into `eval_text`, once inside a `while`. Add any new
  function that takes those two types and is called from this page, and the
  check starts reporting one of those existing spots instead of the new code.
  What was tried, none of which worked: renaming the locals to dodge a name-based
  rule; moving the new function to a different page (error moved from 150 to
  106, both untouched lines); checking for and ruling out an import cycle; and
  rebuilding the loop's argument each pass with `concat_indices(input,
  list_new())` so the parameter is only ever borrowed. The per-value split in
  `gather` and extracting `per_member`'s mode tail are both correct code and
  both unbuildable today. **Treat this page as frozen for move-heavy work** and
  put anything new that needs a loop over the input behind a builtin instead,
  the way `getpath` and `first`/`last` were.
- **`length` of a number is its absolute value, and of a null is 0.** jq reads
  `1|length` as `1`, `-7|length` as `7`, `-2.5|length` as `2.5`, and `null|length`
  as `0`; only a boolean has no length and it is an error. Returning `null` for a
  number looked harmless and was not: it silently turned every `| length` after a
  numeric step into a wrong answer, including through `//`, where it read as a
  precedence bug until the arithmetic was traced. A float keeps its written text,
  so the sign comes off the front of that text with `str_sub`, not a conversion.
- **Two pages answering to one function name is a call reaching the wrong body, and
  nothing warns you.** `filter/builtin/path/setpath.oo` and
  `filter/builtin/object/builtin_object.oo` each grew a `grow`. Different shapes,
  different arities, same name. The build was clean, `oodac check` was clean, and
  `line-cap`, `file-law`, `academy`, and `density` were all clean. `setpath` still
  passed every case that never grew an intermediate and died with a core dump or an
  out-of-bounds read on every case that did — which is the worst shape a defect can
  take, because the passing cases are an argument that the code is right. The
  collision only bit once `filter/builtin/rewrite/rewrite.oo` linked both pages
  together, so calling either page on its own in a probe was green. `make
  dup-names` is the gate that now catches this; it is in `verify` for that reason and
  must not be removed because it "has never fired" — it fires on the first careless
  name.
- **A function that is correct in isolation can be wrong in the link graph, so test
  the graph.** Bisecting a miscompile with a probe is the only technique that has
  ever worked on these three defects, but the probe has to import the *same set of
  pages the real entry point pulls in*. A probe importing one page proved
  `builtin_setpath` sound while the binary importing two pages core dumped on the
  same call. The probe that finally isolated it was the one that imported
  `rewrite.oo`, not the one that imported the function under test. When a probe goes
  green and the binary does not, the probe is too small: add its imports before you
  believe it.
- **jq's update operators are macros over `reduce` and `_modify`, and the three
  families do not agree on how many answers they keep.** Measured against jq 1.8.1
  before any of them was written, because the answer is not derivable from the
  spelling and guessing it is how a "supported" operator becomes a wrong one.
  - `= v` is exactly `setpath(P; v)`, empty value and all: `.a = (1,2)` gives two
    objects and `.a = empty` gives nothing.
  - `|= f` keeps only the **first** answer of `getpath(P) | f` (`.a |= (1,2)` is
    one object, `{"a":1,"b":2}`), and when the body answers nothing it **deletes
    the key** rather than setting null: `.a |= empty` on `{"a":1,"b":2}` is
    `{"b":2}`. That is `_modify`'s second branch, and it is the whole difference
    between `= empty` (nothing) and `|= empty` (a deletion).
  - `+= -= *= /= %=` keep **every** answer (`.a += (1,2)` gives `{"a":2,...}` and
    `{"a":3,...}`) and answer **nothing** when the body does, with no deletion
    branch: `.a += empty` is nothing, where `.a |= empty` is `{"b":2}`.
  - `//= v` reads its right hand side **eagerly and independently**. `.a //= empty`
    on `{"a":1}` is nothing even though `1 // empty` is `1`, and
    `.a //= error("boom")` on `{"a":1}` raises the error even though `1` is
    truthy. So it cannot be written as `_modify(P; . // v)`. `.a //= (9,10)` on a
    truthy `.a` gives the same object **twice**, which does not follow from
    `1 // (9,10)` — measured as one answer — so the second answer comes from
    `_modify` itself and is not yet accounted for. **Refuse that one case rather
    than reproduce a count that was measured but not explained.**
- **A comment that names a cause you have not proved is worse than no comment.**
  The `list_push(list_new(), x)` rewrite in `setpath`'s `grow` was made first, on a
  theory about calls nested in the receiver position, and changed nothing. The
  comment written to explain it confidently described a defect that did not exist and
  pointed the next reader at the wrong line. The `nested call` rule in this section
  is real and was violated for real, but not here. If a fix did not change the
  behaviour, say so at the site and move on.

## 7. Verification Gate

```
make verify
```

Runs `line-cap`, `file-law`, `academy`, `density`, `suggest-audit`, `dead-tests`,
`dup-names`, `test`, then `check` on every page. `test` is behavioural: 655 assertions against
the built binary covering selection, indexing, slices, iteration, pipe, comma,
the builtins, escaping, float round trips, the exit-code contract, the three
output modes, file and stdin agreement, and double-run byte identity. No `.json`
fixture ships in the tree because `file-law` forbids the extension; input is
piped through stdin.

**Removing `.ooda-cache` is not enough to make a gate cold.** `$(BIN): $(SRC)`
compares timestamps, so with a binary newer than every source `make build` prints
*Nothing to be done* and the cache you just deleted is never rebuilt — the gate
then runs against the previous binary and reports green. Delete `dist/oojq` as
well, or the "cold" run is a lie. Also note `rm` here is wrapped by `mavis-trash`,
which exits non-zero when the path is already gone, so a `rm ... && make ...`
chain breaks on the success case.

**Take a test's expected value from the reference binary, never from your head.**
Three assertions in a row were written by hand-deriving what a shell pipeline
would print, and all three were wrong while the code was right: a JSON string
that needed `\"` escaping, a `tr '\n' '|'` that also converts the *trailing*
newline, and one that asserted jq's own answer for a case this build had just
documented as a divergence. When a test fails, run the identical pipeline
against `jq` and paste what it prints. `printf '%s' '{"k":1}' | jq -c FILTER |
tr '\n' '|' | od -c` settles it in one step and shows every byte.

`make parity` is separate and is deliberately not part of `verify`: it needs a
real `jq` on the host, and a low number is the honest state of the work rather
than a build failure. It runs every case in all three output modes — plain,
`-c`, and `-r` — so a change to the writer is caught against the whole corpus and
not only by the handful of assertions that mention it.

`make sweep` is a third layer, on a corpus deliberately disjoint from the parity
one. Parity only grows where a divergence was already found, so it confirms and
never discovers; the sweep corpus in `qa/sweep_cases.txt` is the only thing here
that can find a class of input nobody thought of. It found `max` keeping the
earlier of two equal values and an `if` branch being handed the condition's
answer, both of which the whole parity corpus had passed. `verify` does not run
it, for the same reason parity is not in `verify`.

**The percentage measures the corpus, not the program.** It has moved in both
directions while the code got better, because hard cases get added and a refusal
on a case jq answers costs the same as being wrong on it. Read the byte-identical
count and the unsupported list together, never the ratio on its own. Every one of
the 30 refused cases is a boundary written down in the README: six non-square
`sqrt`, two quotients that do not terminate, the pre-existing
`contains(["x"])`, and `test` on a pattern the std NFA cannot honour.

**Never read a gate through a pipeline that hides its exit status.**
`make verify 2>&1 | grep … | tail` reports the exit code of `tail`, which is
always zero. A cold verify that died in the build — killed for memory on a
shared machine, with another project's compiler taking eight gigabytes at the
time — printed seven green gate lines and looked like a pass. `make test` on its
own, with no pipe in front of it, gave `669/669` and `RC=0` minutes later. The
rule is the same one as "run a gate cold": a result read through a filter is a
result about the filter. Redirect to a file, echo `$?`, then read the file.

**Run a gate cold before believing it.** `rm -rf .ooda-cache` first. A warm cache
once hid a `Result[SRes, String>` in the tree while `build` and `verify` both
reported green, and it took clearing the cache to see it. See the first entry in
section 6.

**Adding a fix means adding its regression.** Every one of the wrong answers
above got a test in the same increment that fixed it, and the expected value was
taken from `jq` by running the identical pipeline — not written from the shape
of the answer. Six of my first twenty-one expectations were wrong in ways that
had nothing to do with the code: a trailing newline in the comparison, and one
pair of values I had mentally transposed. `oodac check` was right and my
expectation was not, which is the only order that happens in.

**`$(...)` drops a NUL byte from both sides of a comparison.** The parity
script captures output through command substitution, so a case whose answer
contains a NUL — `"AA=A"|@base64d` writes one — is compared with the byte
removed from *jq's* output as well as oojq's. The comparison stays symmetric and
therefore still meaningful, but such a case is not testing the byte. Comparing
through a file per case would fix it and is not done here; the caveat is the
reason it is written down.
