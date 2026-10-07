# oojq

> **A jq replacement, written in the openOODA language.**
> *Reads a JSON document, applies a jq-style filter, emits values as JSON.*

Part of [openOODA-tools](https://github.com/openOODA-tools).

---

## 1. Status

**The CLI works and is byte-compatible with jq where it overlaps.**
`parse/`, `filter/`, and `render/` are implemented and `main.oo` wires them to
argv. 1036 behavioural tests and all eight governance gates pass.

Current parity against jq 1.8.1, measured by `make parity`: **98%** of the
filters jq accepts, byte-identical in every output mode — 2433 byte-identical,
27 refused, 6 answered differently across the three output modes. The case list
is the full set in three output modes, not a curated subset, and a case where
both binaries answer differently is printed on its own line rather than folded
into either total, so the number cannot flatter the implementation.

A second, deliberately disjoint corpus runs under `make sweep`. It is blind to
the parity corpus on purpose, and it is the only layer that can find a class of
input nobody thought of. Two bugs came out of its first run and both are now
closed: 426 byte-identical, 12 refused, 3 answered differently, 97% of the
cases jq accepts. See
[How the answers are checked](#6-verification--governance).

**The percentage measures the corpus, not the program.** Read the byte-identical
count and the refusal list together, never the ratio alone. The loop runs every case
in all three output modes, so a refused case is counted once per mode: the 27
refusals are **9 cases**, and every one of them is a boundary written down here
rather than a hole.

- **6 `sqrt`** of a value that is not a square, which has no exact answer here.
- **1 `test`** on a pattern carrying a character class, which the std regex
  engine cannot honour.
- **2 `strftime`**, both deliberate and both reasoned in [UTC dates](#utc-dates):
  `%s`, which jq answers in the machine's own timezone — three different values
  for one input, measured — and a format written as a generator, which the hub
  refuses for `index`, `rindex`, `contains`, and `error` too, because the
  literal-argument path can only carry one value.

Four more `strftime` cases are in the corpus but are *not* in that 27: jq rejects
them outright (`strftime(1)`, a bare `strftime`, and two bad datetime values), so
the loop never reaches oojq and books them as cases jq rejects rather than as
parity requirements. They are covered by `make test` instead. Nothing else in the
corpus is refused.

Two cases are answered differently (the sweep counts each over a few inputs, so the
raw "answered differently" line reads higher). They are in the corpus on purpose and
they fall into two groups, because *differs* and *is wrong* are not the same
thing and only one of them is a defect.

**One is oojq being wrong, and it is the real state of the build:**

- `"i+/v"|@base64d` writes three `U+FFFD` where jq writes two. Only the number of
  replacement characters in already-invalid UTF-8 differs; the decoded characters
  never do. This one is left open **on purpose**, and the reason is worth stating
  because it is a trap rather than a chore: jq's error-recovery rule is not any
  standard, and measured across 38 sequences it is not even self-consistent in the
  way a rule usually is. `c2 41` decodes to `U+FFFD` then `A` — the bad byte is kept
  — while `e0 41` decodes to a single `U+FFFD`, consuming the `A`; a two-byte lead
  behaves differently from a three-byte one with the identical following byte, and
  `f7` is not treated as a lead at all. That is a quirk of the specific decoder jq
  links, so matching it means copying an accident, and the accident is *when to
  swallow the bad byte*, which sits one step from the valid path. A speculative
  reimplementation here would risk corrupting well-formed UTF-8 — the part anyone
  actually reads — to get a replacement-character count right on bytes that were
  already invalid. **The decoded characters agreeing is the property that matters,
  and it holds.** See the `@base64` note below.

**The nineteen arithmetic cases are all byte-identical to jq now.** They used to
fill this section: `0.1 * 0.2` answering `0.020000000000000004`, `0.1 + 0.2 > 0.3`
answering `false`, `3.3 / 1.1` answering a flat `3`, `5.5 % 2` answering `1.5`. Every
one of them was fixed by *matching* jq rather than by out-arguing it, and that is the
recurring lesson here. A jq replacement's selling point is that a migrating script
does not change under it, and an answer that differs on a non-integer operand with
nothing erroring is a compatibility break wearing the costume of a virtue. `%` was
the sharpest case: jq's is not a remainder at all — it truncates both operands, so
`5.5 % 2` is `1` and `1 % 0.5` is refused — and oojq wrote the mathematically correct
`1.5` for a while before reversing to jq's `1`. The arithmetic case was a good one
and it is still true, but it was not the question being asked.

**One divergence is left in the arithmetic, and it is deliberate.** It is
exactness past a double, on the whole-number path. `9223372036854775807 + 1` is
`9223372036854775808` here and `9223372036854776000` in jq; `9007199254740993 / 1` is
`9007199254740993` and `9007199254740992`. jq's answers are the doubles next to them.
The *literal* cases are byte-identical — `18446744073709551615` prints as itself in
both — and so is `18446744073709551615|length`. A 63-bit `Int` holds what a double
rounds away, and a jq replacement that returns `18446744073709552000` for a number
that was written in full is lossy. This is the one place oojq answers a different
number than jq on purpose, and being different is the point: the exact decimal path
is kept for two whole numbers precisely so a sum or a quotient past 53 bits keeps
every digit, and `/` falls back to the double only where that path cannot finish
(`1/3` is jq's `0.3333333333333333`, where it used to be a refusal, while `10/4` is
still the exact `2.5`). It is the decision most deserving a second opinion and it is
written down here rather than hidden.

**Closing the float gap was reachable, and it has been measured rather than
assumed.** It was the largest parity item by a wide margin — 17 of the 20 cases
above — and the thing worth knowing is that it is *not* blocked by the language.
The compiler has a `Float` and real IEEE arithmetic, and Int has `&`, `|`, `^`,
`<<`, and `>>` with a 53-bit significand surviving a shift intact. What a Float
cannot do is become a value: the runtime has 149 helpers and no float-to-String
among them, so the compiler answers `ERR llvm float to_string needs a runtime
helper` and a printed double can never be stored. The way past that is to do
binary64 on `Int`, and the crux — turning a decimal literal into bits — is written
and checked.
`filter/eval/float/decimal_bits.oo` turns written decimal text into the 16 hex digits
of the binary64 word it is, correctly rounded, with no wide integer anywhere: the
fraction is doubled from the right, the integer halved from the left, the first 53
bits are the significand, the 54th is the guard, and what falls below is the sticky.
It matches an independent oracle (Python's `struct`, a separate implementation of
the same standard) on **5821 cases with zero mismatches**, including 13 exact
round-half-even ties, 24 exact decimal expansions of real doubles up to 1074
digits, 1200 long digit runs, and 439 expected refusals. The smallest normal double
comes back `0010000000000000` and the largest finite `7fefffffffffffff`.

**The other half of the round trip is written and checked too.**
`filter/eval/float/exact_digits.oo` writes out the exact decimal value of a
double — every double is a dyadic rational, so that value is exact and finite,
and the widest one in range is 767 digits across. `filter/eval/float/bits_text.oo`
takes the word apart, expands it, and then drops digits one at a time while the
word still reads back the same, testing each candidate against the converter that
wrote it. **1269 cases come back byte-identical to jq's computed output**, and
the same corpus confirms jq is itself shortest-round-trip in 1269 of 1269, so
this matches jq exactly rather than approximately. `0.1` prints `0.1` and not the
55 digit number it actually is.

**And the arithmetic on top of them works, which is the part that was actually
wrong.** `filter/eval/float/float_word.oo` and `float_ops.oo` add, subtract,
multiply, and order two doubles by doing the arithmetic *exactly* and rounding
once at the end. A double is a dyadic rational, and dyadic plus dyadic and
dyadic times dyadic are both exact, so there is no floating point to model: the
digit-run arithmetic that was already here does the work, and the converter that
was already here does the single rounding IEEE asks for. **6676 cases come back
identical to Python's IEEE binary64, zero mismatches**, including all 852
subnormal cases and every underflow-to-zero case. `0.1 * 0.2` is now
`0.020000000000000004` and `0.1 * 0.2 > 0.02` is true, which it is not today —
and of the 17 float divergences, 5 were comparisons and therefore *wrong answers*
rather than alternative renderings.

Division is the one operation this approach cannot do by the same route, because a
quotient is not dyadic and so has no exact digit run to hand to `decimal_bits`. It
is written anyway, in `filter/eval/float/flt_div.oo`, and it is the part of the
float work that is a proof rather than a very good guess. Seventeen digits of each
operand are long-divided — seventeen is the most a 63-bit `Int` holds while leaving
`remainder × 10` below the top of the range — which gives seventeen digits of the
quotient, one place short of the seventeen a double is pinned by. The gap is closed
by taking the **exact** residual with `dd_mul` and dividing *that* by the divisor
for eighteen more places: thirty-three digits, a thousand times past what the
rounding can notice. Rounding those once with `decimal_bits` gives a candidate, and
a candidate can be one out when the true quotient lands on a midpoint, so the two
midpoints bordering it are built exactly, multiplied by the divisor exactly, and
compared with the dividend exactly. Every answer is one a comparison confirmed. The
algorithm was checked against CPython's correctly-rounded division on **4839 jq
cases and 40000 random doubles with zero mismatches**, and ties round to even.

`3.3 / 1.1` is now `2.9999999999999996` and `3.3 / 1.1 < 3` is true, both as in jq;
before this the exact long division answered a flat `3`. Two whole numbers still
try the exact long division first — it is the only route that can answer a quotient
past the 53 bits a double holds — and the double takes over only where that path
refuses, so `1/3` is jq's `0.3333333333333333` where it used to be a refusal while
`10/4` is still the exact `2.5`.

### UTC dates

`gmtime`, `mktime`, `todate`, `fromdate`, and `fromdateiso8601` are implemented in
`filter/builtin/date/`, with no clock and no timezone anywhere: they are one
era-based calendar formula run forwards and backwards, so the whole family is
deterministic and testable against jq with fixed inputs. `gmtime` writes the
broken-down array jq passes around — `[year, month, day, hour, minute, second,
weekday, yearday]` with the **month counted from zero** (6 is July), the **weekday
from Sunday**, and the **yearday from zero** — and `mktime` reads the first six back
and ignores the last two, because a caller that hand-builds `[2000,0,1,0,0,0,99,999]`
means the first six. `-1|gmtime` is 1969-12-31 at 23:59:59, and `todate` is ISO
`YYYY-MM-DDTHH:MM:SSZ`. **89 of 91 measured cases are byte-identical to jq.**

The two that are not are the same case twice, and they are one of jq's accidents
rather than a rule: **jq refuses `mktime` for 1969-12-31.** `[1969,11,31,…]|mktime`
and `-1|gmtime|mktime` both raise `invalid gmtime representation`, while every
other date round-trips — it is an artifact of the C library at the epoch boundary,
not a rule jq chose. oojq answers `-1`, which is what 1969-12-31T23:59:59Z *is*.
Replicating a C-library boundary bug is not jq-compatibility, so this is left as a
deliberate one-case divergence. The lesson matches the float work: a rule read off
jq has to be tested on a second shape of expression before it is believed.

`strftime` is the sixth member of the family, in `filter/builtin/date/strftime.oo`, and
it takes both shapes jq takes: a **number**, read as seconds since the epoch exactly as
`gmtime` reads it, or the **eight-slot array**, normalized the way a C `struct tm`
normalizes. That normalization is not a detail — it is most of what `strftime` is. A
month past December rolls into the next year, a day of `0` is the day *before* the
first, an hour of 25 is one o'clock the next day, and slots 6 and 7 are ignored and
recomputed from the date. So `[]` is `1899-12-31 00:00:00` (the zeroed struct, which is
1900 less one day) and `[-1]` is `-2-12-31`, because a year of −1 with a day before its
first January is a year of −2. Every base code is implemented — `%Y %y %C %m %d %e %j
%H %I %M %S %p %a %A %b %B %u %w %U %W %G %V %z %Z %n %t %%` — along with all eight
composites, which are pushed back onto the format queue so `%c` and `%F` are each
defined once. `144 of 146 measured cases are byte-identical to jq**,` including `%X`
being the twelve-hour clock (`02:30:25 PM`) where C would give `%H:%M:%S`, and `%y`
wrapping so a year of −1 is `99`.

The two that are not are refusal *wording*: `strftime(["%Y"])` and `strftime(null)` get
oojq's generic "needs a scalar literal argument" where jq says `strftime/1 requires a
string format`. Both refuse, which is what matters; neither answers wrongly.

**`%s` is refused, and that is the interesting decision here.** jq's `%s` is not the
epoch of the instant being formatted — it is `mktime` of a *wall clock*, so it reads in
the machine's own timezone. Measured here: `1425601825` on this host, `1425565825`
under `TZ=UTC`, `1425533425` under `TZ=Asia/Tokyo`, all for the same input. oojq has no
timezone database and no clock, so the UTC epoch would be the right answer for exactly
one of those machines and silently wrong on every other. It refuses the whole call with
the reason: `strftime format code %s needs the local UTC offset, which this build cannot
read`. The same reasoning is why `now`, `localtime`, and `local` are still absent, and
why the *rest* of `strftime` — including `%Z`, which jq also always writes as `GMT`, and
`%z`, always `+0000` — is implemented rather than refused alongside it. A value that is
right on one machine and wrong on the next is not an answer; it is a coin toss.

`strptime` is the seventh, in `filter/builtin/date/strptime.oo` with its three
helpers, and it is the one where **the contract had to be measured rather than
assumed — twice.** An earlier reading of jq said the composite codes could not be
parsed at all. That reading was wrong, and it was wrong because of a shell
escaping bug in the probe itself: the format string reached jq as `%%F` instead
of `%F`, every case failed, and "all eight refuse" looked like a clean finding.
Re-measured one escape level down, **seven of the eight composites parse** and
only `%c` is refused, for every one of seven different input shapes. The same
second measurement found that **jq's reading table and its writing table
disagree in one place**: `%x` is `%m/%d/%Y` when reading and `%m/%d/%Y` when
writing is `%m/%d/%y`, so `"03/05/15"` is 2015 under `%D` and 15 under `%x`.
That is why the composite table lives in its own page, `parse_codes.oo`, spelled
once, rather than inlined in the walk where a copy could drift from `strftime`.

Across 401 measured cases the implementation is **byte-identical to jq on 297**
and every one of the remaining 104 is a refusal. There are no wrong answers.
The refusals fall into exactly three kinds, and the count of each was taken by
reading the answers rather than by assuming:

- **86 rest on a slot jq never computed.** A format naming no date — `"14"`,
  `"%H"`, `"%T"`, `"%p"`, `"%Z"`, `"%z"` alone — leaves jq's weekday and day of
  the year as whatever its C stack held. The signature is stable and is not a
  valid date: slot 6 is `8`, which is not a weekday, and slot 7 is `367`, which
  is not a day of any year that has one. Every one of the 86 was checked to carry
  one of those before being counted.
- **5 are jq's ninth element.** **jq's `strptime` does not require the format to
  consume the whole input.** What is left over is appended to the answer as a
  ninth element — a **String** where the ninth element of `gmtime` is an
  **integer** UTC offset. `"2015 extra" | strptime("%Y")` answers
  `[2015,0,0,0,0,0,3,-1," extra"]`. oojq refuses and says which text was left
  over, because a number slot holding text is not a shape worth reproducing.
- **12 are cases jq also refuses**, differing only in wording.

The rest of the contract is implemented because it was measured, and several
parts of it are not what a first reading suggests. **A day of the year fills in
the month and the day independently**: `"2015 064 9" | strptime("%Y %j %d")` is
the 9th of March, and `"2015 9 064" | strptime("%Y %d %j")` is the same date,
because `%d` wrote the day and `%j` wrote the month whichever order they appear
in — but a month already named is left alone, so `"2015 12 031"` is the 31st of
December. A yearday that walks off the end of its year gets jq's own nonsense
answer, a **month of 24** and a day of 31, while still taking the weekday from
the real date a year on: `"2015 366"` is a Friday and `"1900 366"` a Tuesday,
both of them nameable and both shipped. `%Z` runs to the next **blank** and not
to the next dash, so `GMT-2015` is one token and `"%Z-%Y"` finds no dash to
match. `%u` counts seven days to Sunday, so `7` is `0`. `%z` checks its minutes
and not its hours: `+2500` and `+9900` are accepted, `+0060` is refused. And a
name is matched in full before its first three letters, which is the whole
difference between reading `March` as `March` and reading it as `Mar` with `ch`
left over.

That last one was found by a harness, not by reading, and it is the shape of
thing this project keeps finding: **the first implementation of a reader that
returns two answers conflated them.** One `Int` was carrying both "March is
month 2" and "the match ended at 5", which works for every case where the two
coincide — `Mar` — and is wrong for every case where they do not. Four wrong
answers came out of that one page, and none of them would have been found by
testing `Mar` alone.

### Two builtins, one shape each

`has` and `join` were both wrong, and both were wrong the same way: each had
one shape in mind and coerced the rest into it. `has` asked an object whether
it carried a name, so `{"a":1} | has(1)` answered `false` where jq refuses, and
the refusal names both sides — `Cannot check whether object has a number key`.
`join` accepted an array of strings, so it refused `[1,2,3] | join(",")` where
jq answers `"1,2,3"`, and — worse — it read its **separator as text**, so
`["a","b"] | join(1)` answered `"a1b"` where jq refuses outright.

That last one is the interesting half. **jq's `+` does not coerce**: a string on
the left concatenates a string, leaves itself alone for a null, and refuses a
number, a boolean or a container. `"a" + 1` is an error in jq, not `"a1"`.
`join` is a reduce whose every step is an ordinary `+`, and the two operands are
treated differently on purpose. The **member** is spelled to text first, which
is why `[1,2,3]` joins at all and `[[1],[2]]` does not join at all. The
**separator** is added as it was written, which is why `join(1)` is a refusal
and `join(null)` is a no-op. The accumulator is written into the arena as it is
built because the refusal names the string that had been *reached*:
`{"a":1,"b":[1,2]} | join(",")` fails on
`string ("1,") and array ([1,2]) cannot be added`, with the comma already inside
the quoted half.

An object joins its **values**, in the order it already holds them:
`{"b":2,"a":1}` is `"2,1"`, not a sort. A null member is the empty string, so
`[1,null,true]` is `"1,,true"`. A non-iterable input is
`Cannot iterate over null (null)`, with the value written the way it was
written.

`has` has a rule worth naming, because it looks like it needs a rounding and
does not. jq tests `0 <= trunc(n) < length`, and `has(-0.5)` is **true** — which
is what shows it is not testing `0 <= n`. For an integer length that collapses
exactly to `n > -1 and n < length`, so a float key is answered by two exact
comparisons and never by a truncation this build has no way to take. A null
input is `false` for every key kind, including the ones an array would refuse,
because there is no shape left to ask about.

Both are measured rather than asserted: **64 of 64 `has` cases and 51 of 51
`join` cases are byte-identical to jq 1.8.1**, every refusal sentence included.

### The third one was the same bug wearing a different hat

`add(f)` used to be refused, and the refusal was correct — it just said so
awkwardly. The reason it was refused at all is the third instance of the shape
this section is about. `add` had one shape in mind, an array of numbers, and
`add(.)` was read as "sum the members", so `[1,2,3] | add(.)` answered `6` where
jq answers `[1,2,3]`. That is a **different number**, not a different shape, and
it is the worst kind of gap because nothing about it looks like a gap.

The rule is jq's own definition: **`add(f)` is `[f] | add`.** The filter runs
once over the whole input and *every answer it gives* is summed. Measured, that
is the whole of it:

| filter | answer | why |
|---|---|---|
| `[1,2,3] \| add(.)` | `[1,2,3]` | one member, the input itself |
| `[1,2,3] \| add(.[])` | `6` | the collect holds the three members |
| `[1,2] \| add(.[0], .[1])` | `3` | a top-level comma is one argument |
| `[1,2,3] \| add(empty)` | `null` | an empty collect is an empty array |
| `[1,2,3] \| add(.;.)` | refused | a semicolon is `add/2`, and there is none |

So it is a **parse-time rewrite** to `[f] | add`, in
`filter/builtin/rewrite/rewrite.oo`, which costs the evaluator nothing: a collect
already walks the body and the bare `add` already sums an array. That is the
same bargain `recurse`'s two-argument form and `map_values` already take.

The one case that would have been a **wrong answer** rather than a gap is the
last row, and measuring found it before writing anything. A top-level comma is
one argument holding a generator, so `add(.[0], .[1])` is legal and is `3`. A
top-level **semicolon** is a *second argument*, and jq answers
`add/2 is not defined` — so a body carrying one is refused by name, using the
module's existing `semi_at_top`, rather than collected into `[a;b]` and summed.
Saying "a semicolon is a second argument" is the difference between a refusal a
reader can act on and a number they cannot explain.

**46 measured cases, 42 byte-identical, 0 wrong answers.** The four differences
are all refusals on both sides: `add()` and `add( )` are syntax errors in jq and
`"add()" needs an argument in this build` here, and `add(f)` with an undefined
name is `f/0 is not defined` in jq and `unknown builtin "f"` here.

### The failure that looks like a pass

The kind matrix — every dispatched builtin against every input kind against
every scalar argument, 4 620 cases — is the layer that keeps finding things
reading does not. Its latest run reported **714 cases where one side answered
and the other did not**. Almost all of them were one defect wearing many names:

```
1          | tonumber("b")     ->  1     jq: tonumber/1 is not defined
"abc"      | length(1)         ->  3     jq: length/1 is not defined
"abc"      | type(1)           ->  "string"
1.5        | ascii_upcase("b") ->  1.5
```

oojq read the body and **ignored it**. The value it produced is the correct
answer to the call the reader did *not* make, which is the worst shape a wrong
answer can take: it is silent, it is plausible, and nothing about it looks like
a gap. Across 21 builtins that is ~700 cases, and a test written against
`length(1)` would have recorded `3` as correct.

The repair is a parse-time refusal in `filter/builtin/rewrite/arity.oo`, and the
name list is **measured, not remembered**. Each of the 94 names this build knows
was asked about at arity 1 *and* at arity 2 against jq 1.8.1:

- refused at **both** → the name takes no body at all. 47 of them.
- refused only at arity 1 → it keeps its two-argument form. That test is what
  keeps `sub` and `gsub` out of the list: `sub("a")` is `sub/1` and does not
  exist, `sub("a";"b")` is `sub/2` and does. Listing `sub` would have refused a
  call that works.

It is a **deny-list**, not an allow-list of what takes a filter, on purpose. Every
name left out behaves exactly as it does today, so a builtin that takes a body
and is not listed is a coverage gap rather than a working call that stops
working. Both directions are gated: 47 of 47 listed names refuse with jq's own
`length/1 is not defined` sentence, and 47 of 47 others — `first`, `last`, `map`,
`any`, `sort_by` — still take their bodies.

The same run found one more, in the opposite direction: oojq was *refusing*
something jq answers. `contains` over two booleans. jq says a boolean contains
**itself** and not the other one, so `true|contains(true)` is `true` while
`true|contains(false)` is refused. The test here had been "the two kinds match",
which is the same for every kind pair except this one — and for this one it
answered a value where jq gives a refusal.

**714 → 17.** Of the 17, six are the deliberate `index`-into-an-object refusal
and eleven are `range` with a float bound, which is a gap rather than a wrong
answer: oojq answers `range needs whole numbers` where jq answers `0 1`. The
rule there is exact and is the next thing to implement — `range(from; to; by)`
emits `from, from+by, …` while the next value is `< to`, in real numbers, so
`range(0.5;2.5)` is `0.5 1.5` and `range(1.5)` is `0 1`.

### A construct refused in one position and not the other

`1 as $x | $x` answered `unexpected "a" at character 3`. The same word at the
start of a filter was refused properly — `binding a variable with "as" is not
supported in this build` — so the construct was readable in one of the two
places a reader would write it, and the message at the other named neither the
construct nor the reason.

It was not only `as`. Every reserved word behaved this way, because all of them
are recognised in one place only:

| filter | before | after |
|---|---|---|
| `1 as $x \| $x` | `unexpected "a" at character 3` | `binding a variable with "as" is not supported…` |
| `1 reduce . as $x (0;.)` | `unexpected "r" at character 3` | `"reduce" is not supported…` |
| `1 def f: 1; f` | `unexpected "d" at character 3` | `"def" is not supported…` |
| `1 label $out \| 1` | `unexpected "l" at character 3` | `"label" is not supported…` |

Nineteen lines in `filter/syntax/parse_top.oo`: when leftover text begins with an
identifier that is a reserved word, that word's own sentence is returned.
`reserved_word` became public so the two positions share one list rather than
two drifting copies.

The part that matters more is what it must **not** do. A leftover that is not a
reserved word still gets the generic `unexpected` message, so `1 2`, `1 @` and
`.a b` still say `unexpected "2" at character 3`. A fix that swallowed every
leftover would look tidier and would hide a real syntax error behind a sentence
about a feature, so the harness checks the generic path as well as the new one,
along with six ordinary filters that must still parse.

### A counter nobody can read is a counter nobody can hold to

`make parity` reported `jq rejects case 135 (not a parity requirement)` and moved
on. That number had gone to 213 by the time anybody looked, and **78 of those
cases were not jq being careful — they were my own typos**.

A parity case jq cannot compile contributes nothing: it is neither agreement nor
divergence, so it can never fail and never teaches anything. Ten new cases
looked fine in the source and were silently inert. Eight of them were not valid
jq at all, because only `as` binds an expression on its left — `1 reduce …`,
`1 def …` and `1 label …` are syntax errors, so the corpus was scoring nothing
for them.

Both loops now print the cases jq refuses, sorted, the way the refusal list is
printed:

```
  jq rejects case 177  (not a parity requirement, listed below)
  the cases jq ITSELF refuses, printed because a counter nobody can read is a
  counter nobody can hold to:
  jq refuses  0.1%0.05
  jq refuses  1%0.3
  jq refuses  [[1,2]]|@csv
```

That is the same lesson as printing refusals rather than counting them, applied
to the bucket that was hiding the typos. It is the bucket a malformed case lands
in, which makes it the one bucket that must be readable.

The eight invalid cases came out of the corpus — their refusal messages are
pinned by `make test` assertions, which is the right place for them, since parity
cannot score a filter jq will not parse. What stayed is the three that are real
jq: `1 as $x | $x`, `as $x` and `.a as $x | .`, and those now show up honestly as
**unsupported** rather than as nothing at all.

A related trap, in the same edit: `$$` is how a `$` reaches the shell from a
recipe, so `1 as $x | $x` in a Makefile arrives as `1 as  |` — a mangled filter
that jq also rejects, and so was equally invisible. `make -n parity | grep` is
how that one was found, and it is the cheapest way to see what a corpus entry
actually became.

### A feature that looked like a free rewrite, and was not

`//=` is the obvious sibling of `|=`, and the two look interchangeable:

```
.a //= 9     jq:  {"a":1}     (1 is truthy, so nothing changes)
.a |= (. // 9)  the same thing
```

Measuring them against each other across ten shapes found two where the rewrite
is **silently wrong**, and both are the same cause — jq reads the right-hand
side **eagerly**, before it looks at the left:

| filter | jq | the `\|=` rewrite |
|---|---|---|
| `.a //= (empty)` | **nothing** | `{"a":1}` |
| `.a //= error("x")` | **error: x** | `{"a":1}` |
| `.a //= (1\|debug)` | `["DEBUG:",1]` | `{"a":1}` |

The first is not expressible at all: `//=` with an empty right-hand side
produces *no output*, and `|=` assigns a value, so it cannot say "this
assignment happened to nothing" — that needs a binding, and this build has no
variables. The other two are the same eagerness seen from two sides.

So the rewrite was not taken. It would have converted a **loud** refusal into a
**quiet** wrong answer, which is the one trade this project will not make for
convenience. What changed instead is that the decision is now on the record: the
refusal names both divergences and says the `|=` spelling is "silently wrong for
an impure right hand side", and seven assertions generated from live jq pin the
whole boundary — including that `.a |= (. // 9)` *is* supported here, that it
fills a null the way jq does, and that it leaves `0` and `""` alone because
**both are truthy in jq**, which is the part most likely to be got wrong by
anyone reading the table above and assuming "falsy" means "null and false".

Everything else about the operator was already right. `.d //= 9` leaves `d` at
`0` and `.e //= 9` leaves `e` at `""`; a missing `.z` is created. The gap was
never the semantics, it was one unreachable corner of them.



jq turns out to have **two** ways to write a double and they disagree: a number
parsed from text keeps its point and takes `1E+16`, while a computed one loses
the point when it is whole and takes `1e+16`. The computed path is what the
parity corpus compares against, and its rule is not the one a standard suggests
— scientific notation is used below `1e-4`, or when the full form would end in
sixteen or more zeros after the significant digits, which is why `1e+16` is an
exponent and `1.1e+16` is not.

**None of it is wired into the value tree yet, and that is deliberate.** No value
is a double and no arithmetic sits on top; the point of building both ends alone
is that a wrong bit in the arithmetic would otherwise be indistinguishable from a
wrong bit here. Subnormals and overflow are refused by name rather than answered
approximately. Cost is 0.02 ms for a typical literal read, but the exact expansion
is far heavier — about 0.6 s per value in the worst case — and the arena never
frees, so a single process degrades after roughly 130 conversions and starts
returning NUL bytes. That is a measured limit, not a rounding error, and the fix
is a reusable buffer the language does not have. The full evidence and the eight
traps that produced wrong answers along the way are in AGENTS.md.


**One builtin is oojq-only, and it has no jq counterpart to differ from.**
`leaf_paths` is not a jq 1.8.1 builtin — `jq -n 'builtins'` does not list it and
jq refuses it as undefined at both arities. It answers every path to a
non-container, and it counts `null` as a leaf, so it is `paths(scalars)` plus the
nulls: on `{"a":{"b":1},"c":[2,{"d":3}],"e":null}` it gives `[["a","b"],["c",0],
["c",1,"d"],["e"]]` where `paths(scalars)` stops before `["e"]`. It is listed here
because the parity corpus can never check it — jq rejects every case — and because
it shipped for a long time with no test at all. Three now pin its definition.

**A slice whose bound runs past the end used to kill the process.**
`[1,2,3][0:5]` answered nothing — it read off the end of the children and died
on an out-of-bounds read, where jq answers `[1,2,3]`. The end of a slice was
translated into a position without ever clamping it to the array's length, so
`[1,2,3][1:99]`, `[][0:2]`, and `[1,2,3][2:5]` all died the same way. Every one
of 531 tests missed it, because the only slice in the corpus was `.tags[0:1]`,
comfortably in bounds. This is the worst failure mode in the project — not a
plausible wrong answer but a death — and it lived on an input nobody thinks
about, because nobody writes `.[0:5]` when they already know the length is 3.
It was `limit(n; f)` that walked into it, by being the first thing here to slice
with a bound it had not verified. Four cases now cover the class, not just the
one that tripped.

A test score cannot see this class of bug, and four of the eleven were not
arithmetic at all until this increment found them. `.a + .b` — the commonest jq
idiom there is — was silently evaluating `.b` against `.a`'s value, so
`.ratio + .port` raised `cannot index a float with "port"`. `add` summed the
integer part off every member, so `[1, 2.5] | add` answered `1` with the `2.5`
dropped. `min` and `max` did the same, so `[1.5, 2.5] | max` answered `1.5`.
Every one of them passed the whole corpus, because the corpus had the right
shape and the wrong contents: every case with a `.` on the right of an operator
was a literal or a wrapped `(.a)`, and every case of `add` was all-integer.
**After a fix lands, the question that finds the next one is: what class of
input was never in the corpus at all?** A passing score measures the corpus,
not the program.

The same question found the last of the four wrong answers above, in a place
nobody had looked. A collect `[f]` read its body over the whole stream at once,
so `[1,2,3] | .[] | [.]` was `[[1,2,3]]`. It had been written down as
unbuildable for a long time: the loop it needs has to live in `gather`, on the
one page that is already at its line ceiling. The fix was not a new loop. It
was noticing that `per_member` *already* walks values one at a time and gathers
each one's answers for `map`, and that a collect is `map` pointed at the value
itself rather than at its members. `gather` became a call with a different mode,
four conditions grew an `||`, and a line came back. **A page at its ceiling is a
constraint on writing, not on designing.**

Asked once more, that question found the largest class in this build, and it is
one sentence long: **every step above a field access is a per-value step, and
three of them were reading the whole stream at once.** `.items[] | .id * 2`
answered `2 4 6 2 4 6 2 4 6` — the left side over three values is three, the
right side `2` over three values is also three, and the cross product is nine.
`.items[] | .id, .k` answered `1 2 3 "a" "b" "a"` where jq reads them in step.
`.items[] | if .id==1 then 1 else 2 end` answered 27 values. A question mark had
the same shape: `(.a,.b) | .c?` was nothing, because the first refusal ended the
walk and took the good answer with it. The corpus had three hundred cases and not
one put an operator, a comma, or a conditional *downstream of an iterate* — the
iterate was always consumed by `map`, `select`, or a field. **A corpus needs
cases where the previous step changes the arity of the next one, not only cases
where it does not.** All four are now one rule and one loop.

Two more came from the same question asked of the numbers. A literal wider than
a 64-bit `Int` wrapped: `18446744073709551615` decoded to `-1` and
`100000000000000000000` to `7766279631452241920`. An `int × int` fast path
wrapped too, so `9223372036854775807 * 2` answered **-2**. A negative zero was
not a number at all: `0 * -1` answered `0` where jq writes `-0`, and `num_cmp`
called `-0 < 0` true. Each was a silent wrong answer, and each is now measured
and byte-identical or named.

And one more, which is the reason a corpus of answers cannot be trusted on its
own: `paths(f)` **read its filter and ignored it.** `[paths(.=="a")]|length`
answered 16 where jq gives 2, and `[paths(empty)]` answered 16 where jq gives 0.
Both look like plausible answers. The walk lives on a page that cannot reach the
evaluator, so `f` cannot be asked; it is now refused by name. A builtin that
cannot run its filter argument must refuse, never run it without.

`@base64` and `@base64d` are both implemented, and `@base64d` follows jq's own
shape rather than the tidier one people assume. jq's decoder is a bit
accumulator, not a four-character block reader: six bits go in, whole bytes come
off, and a `=` ends the run wherever it sits. That is why `"ab"` decodes to one
byte with no padding written, `"YQ==="` decodes to `"a"` with the extra `=`
ignored, and `"A==="` is a trailing byte rather than a bad pad. Both refusal
messages are jq's own, down to naming the string it was given:
`string ("!!!") is not valid base64 data` and `string ("a") trailing base64 byte
found`. The std `base64_decode` disagrees with jq on padding and accepts the
URL-safe alphabet that jq rejects, so it is not used here.

`@csv`, `@tsv`, and `@sh` are all implemented. A row is one flat array, which is
jq's contract and not a limitation: `.[] | @csv` over a stream of rows is how a
whole table is written, and each row is answered on its own. Every string cell
in CSV is quoted and a quote inside it is written twice, so a comma or a
newline inside the cell is just a character; every string cell in TSV has its
backslash doubled and its tab, newline, and carriage return spelled as `\t`,
`\n`, and `\r`, because a literal one would end the cell or move to another
line. A `null` cell is empty in both, which is why `[1,null]` is `1,` and not
`1,null`. `@sh` quotes a string word whatever it holds, closes the quote and
reopens it around an apostrophe, and writes a number, a boolean, or a `null`
bare. A container inside a row, or a container where `@sh` wants one word, is
refused by name rather than written out as JSON and read back as a single cell.

A bare `any` and a bare `all` are the two builtins that are also a filter all on
their own, and both now answer. jq reads a bare `any` as `any(.)` over the
members, so `[false,false] | any` is `false` and `[true,false] | all` is `false`
rather than a refusal. `map`, `select`, and the five `_by` builtins still need
a filter argument and are still refused without one, because they have no
meaning without a condition. The two-argument forms `any(f; g)` and `all(f; g)`
are not supported.

Two things about the pair above are not byte-identical to jq, and both are in
the parity corpus rather than left out:
- The *number* of `U+FFFD` characters can differ when `@base64d` decodes bytes
  that are not UTF-8. jq folds a 3- or 4-byte lead and the byte that fails it
  into one replacement; this build follows the Unicode maximal-subpart rule and
  starts a new one at the next byte. The corpus line
  `"i+/v"|@base64d|utf8bytelength` is the case: jq answers 6, this build
  answers 9. Only the count in already-invalid input changes; the characters
  themselves never do.
- `any` and `all` over something that is not a container are refused by both, and
  the wording is jq's: `Cannot iterate over number (500)`, with the kind jq calls
  it and the value as it is written. `min` and `max` are refused in jq's other
  wording, `number (1) and number (1) cannot be iterated over`, because that is
  what jq writes when it cannot iterate. One sentence, two shapes, both measured
  rather than guessed.

**Every refusal of this kind now says what jq says.** The two sentences jq usesfor indexing and iterating a scalar live in one place, `select_node.oo`, and
every page that refuses one of those ways uses them. This build used to answer
`cannot index a int with "b"` and `cannot iterate over a int`, which are
sentences jq never writes — `a` and `bool` are the words of a value tree, not of
a filter language, and a reader had nothing to compare them against. The
measured rules are narrow and worth stating:

- An index names the value's kind and the key's: `Cannot index number with
  string "a"`, `Cannot index object with number`. A **key** is named by its value
  when it is a string and by what it *is* otherwise, so a position is the word
  `number` and never its digits.
- An iterate names the value and its kind: `Cannot iterate over number (1)`,
  `Cannot iterate over string ("s")`, `Cannot iterate over boolean (true)`.
- A **null is refused by an iterate** and not by an index: `null|.[]` is
  `Cannot iterate over null (null)`, while `null|.a` and `null|.[0]` are `null`.
  A missing member is a null, and it is still a null when indexed.
- One float is still written as it was typed: `1e2|.[]` says
  `Cannot iterate over number (1e2)` where jq writes `1E+2`. That is the float
  rendering gap below, in a sentence rather than in a value, and it is left
  rather than half-fixed for the same reason.

`del(f)` and `path(f)` are both implemented, and both draw their line in the
same place: **the argument must be a literal path expression.** `del(.port)`,
`del(.limits.rps)`, `del(.tags[0])`, `del(.a, .b)`, `del(.)` and `path(.a.b)`
all work, and each is a per-value step, so `[.tags[] | del(.)]` answers
`[null,null]` rather than one `null`. Deleting a key that is not there is a
no-op, which is what `del(.missing)` means, and `del(.)` is `null` because the
last step of a path is the value itself.

A path with an iterate, a slice, a pipe, or recursion in it is **refused by
name** rather than read as far as it looks like a path: `del(.a[])` and
`path(..)` both say so. Reading the part of a filter that happens to look like
a path would answer about a path the writer never wrote, which is the one thing
this document refuses to do anywhere. Closing that gap needs a path mode in the
evaluator, which is a change to the one page that cannot take one.

The one place this build answers where jq refuses is `path(.[0])` written
against an object. jq walks the path and errors on the index; this build reads
it as text and answers `[0]`, which is the path that was written. That is a
refusal replaced by the right answer rather than by a wrong one, and it is the
only difference in this pair.

Not yet built: the AF_UNIX socket in `ipc/`, variable binding (`as $x`), object
construction, and the operators listed under *What Is Not Supported*.

The one place oojq is not trying to match jq is the tool surface. `oojq --mcp`
serves the engine over JSON-RPC and publishes `jq_check` and `jq_grammar`
alongside `jq`, so a caller can ask what the engine supports and validate a
filter before spending a run on it. jq has no equivalent.

`error` is implemented and its message is jq's, down to the `(not a string): `
prefix on a non-string. Two things about it are oojq's own: the line is wrapped
as `oojq: filter "<f>": <message>` because a filter failure is reported the same
way wherever in the filter it came from, and the exit status is `2` where jq
uses `5`, because this build has no second channel to mark a stop as deliberate.

You do not need to quote a filter that contains a space. Every argument before
the first one that names an existing file is treated as filter text, so
`oojq .name, .port server.json` works exactly as it does in jq.

---

## 2. Installation & Verification

`oojq` has zero runtime dependencies. It compiles to a standalone native binary linked directly with the host libc.

### Universal Web Installer
Installs the standalone native binary to `/usr/local/bin` (or `~/.local/bin`) with automatic SHA-256 seal verification:

```bash
curl -fsSL https://openooda-tools.github.io/oojq/install.sh | bash
```

### DNF (Fedora, RHEL, CentOS, Rocky Linux, AlmaLinux)
Install directly from the sovereign release channel or download the RPM package:

```bash
# Direct remote install via DNF
sudo dnf install https://github.com/openOODA-tools/oojq/releases/download/v0.1.0/oojq-0.1.0-1.x86_64.rpm

# Or download and install locally
sudo dnf install ./oojq-0.1.0-1.*.rpm
```

### APT / DEB (Debian, Ubuntu, Linux Mint, Pop!_OS)
Download and install the Debian binary package via APT:

```bash
# Fetch and install via APT
curl -fsSLO https://github.com/openOODA-tools/oojq/releases/download/v0.1.0/oojq_0.1.0-1_amd64.deb
sudo apt install ./oojq_0.1.0-1_amd64.deb
```

### PKGBUILD (Arch Linux, Manjaro, EndeavourOS, SteamOS)
Build and install using `makepkg` and the provided Arch Linux `PKGBUILD`:

```bash
# Option A: From cloned repository
git clone https://github.com/openOODA-tools/oojq.git
cd oojq/packaging
makepkg -si

# Option B: Direct download of PKGBUILD
curl -fsSL https://openooda-tools.github.io/oojq/PKGBUILD -O
makepkg -si

# Option C: Prebuilt Pacman package
sudo pacman -U https://github.com/openOODA-tools/oojq/releases/download/v0.1.0/oojq-0.1.0-1-x86_64.pkg.tar.zst
```

### Clean Uninstallation
`oojq` can be cleanly and completely uninstalled at any time without leaving stray files or broken registrations:

```bash
# Method 1: Using the companion uninstaller deployed with oojq
oojq-uninstall

# Method 2: Via the Universal Web Uninstaller
curl -fsSL https://openooda-tools.github.io/oojq/install.sh | bash -s -- --uninstall

# Method 3: From source repository
make uninstall

# Method 4: Via native package managers
sudo dnf remove oojq        # Fedora / RHEL
sudo apt remove oojq        # Debian / Ubuntu
sudo pacman -R oojq-bin     # Arch Linux
```

### Installer Options
```bash
# Preview actions without modifying the host
curl -fsSL https://openooda-tools.github.io/oojq/install.sh | bash -s -- --dry-run

# Verify cryptographic SHA-256 seal only
curl -fsSL https://openooda-tools.github.io/oojq/install.sh | bash -s -- --verify

# Custom installation prefix
curl -fsSL https://openooda-tools.github.io/oojq/install.sh | bash -s -- --prefix ~/.local/bin

# Simulate clean uninstallation
curl -fsSL https://openooda-tools.github.io/oojq/install.sh | bash -s -- --uninstall --dry-run
```

### Source Build & Verification

```sh
make build       # compile main.oo to dist/oojq
make test        # 1036 behavioural assertions against the built binary
make parity      # byte-compare every filter against the real jq
make verify      # line-cap, file-law, academy, density, suggest-audit, dead-tests, dup-names, check
make package     # build .deb, .rpm, and .pkg.tar.zst packages
make install     # install binary to ~/.openooda/bin/oojq
make uninstall   # cleanly remove installed binary, companion uninstaller, and caches
```



`make parity` runs the same filters through the installed `jq` and through
oojq, in all three output modes — plain, `-c`, and `-r` — and compares the bytes.
It is the honest measure of "is this a better jq", so it is kept out of `verify`
and skips cleanly when jq is not installed.

Requires the `oodac` compiler, found at `~/.openooda/bin/oodac`, falling back to
`../../openOODA/oodac/bin/oodac`. Override with `make OODA_COMPILER=/path/to/oodac`.

**After a compiler update, clear the build cache before the first build.**

```sh
rm -rf .ooda-cache dist/oojq && make build
```

The cache is keyed on the `.oo` files it read, not on the compiler that read them,
so an update leaves it able to hand back the previous compiler's decisions for
pages whose source did not change. The result is a binary that builds cleanly,
passes `oodac check` on every page, and is simply wrong: 381 of the 687 assertions
that existed then failed that way under oodac v2.11.8, in three unrelated families, all of them
values read wrong at runtime. `make build` keys only on the `.oo` mtimes, so it
will not notice that `oodac` itself is newer and may report `Nothing to be done`.

---

## 3. Usage

```
oojq [options] <filter> [file]
oojq --mcp

options:
  -h, --help     display help
  -V, --version  display version
  -c, --compact-output   one value per line without spaces
  -e, --exit-status      1 when the last value was false or null, 4 when
                         nothing was ever produced, as in jq
      --mcp      serve the filter engine over MCP on stdin/stdout

Short flags may be run together, so -ce is two flags.
```

The file argument is optional; with no file oojq reads stdin.

### MCP

`oojq --mcp` speaks JSON-RPC 2.0 on stdio. Frames are `Content-Length` delimited
when the client opens with a header and newline-delimited JSON when it does not,
and every answer reuses whichever the client chose. It implements `initialize`,
`ping`, `tools/list`, and `tools/call`.

It publishes three tools:

| Tool | Arguments | Returns |
|---|---|---|
| `jq` | `filter`, `input` | the results, in the same form the command line prints |
| `jq_check` | `filter` | `accepted`, or the parser's own error |
| `jq_grammar` | — | the filter language and builtin set this build has |

The last two are the reason to run oojq rather than jq as a tool server. A caller
that can ask what the engine supports stops guessing: `jq_grammar` names the
builtins and also names the ones this build **refuses and why**, so a model does
not ask for `ascii` or `splits` and then get an error. `jq_check` answers whether
a filter parses in about a millisecond, which is far cheaper than running it over
a large document and discovering it was wrong.

```bash
# One framed round trip
printf '%s' '{"jsonrpc":"2.0","id":1,"method":"ping"}' | oojq --mcp
{"jsonrpc":"2.0","id":1,"result":{}}
```

### Flags

| Flag | Effect |
|---|---|
| `-c`, `--compact-output` | one value per line, no spaces |
| `-r`, `--raw-output` | a **top-level string** is written as its own text rather than as a JSON string; every other kind is unchanged |
| `-e`, `--exit-status` | exit `1` when the last value was `false` or `null`, `4` when nothing was ever produced |
| `--mcp` | serve the engine over JSON-RPC on stdin/stdout instead of running a filter |

`-r` is the one that makes the table formats usable: `oojq -r '.rows[] | @csv'`
writes a CSV file rather than a file of quoted CSV rows. It changes exactly one
kind, which is jq's rule too — a string at the top level, and nothing else. A
number is still a number, `null` is still `null`, and a container is still JSON
in the spacing `-c` or the default asked for.

Short flags run together, so `-rc` and `-re` are two flags rather than a filter
that starts with a dash.

### Filters

| Filter | Result |
|---|---|
| `.` | the whole document |
| `.name` | one member of an object |
| `.a.b` | a chain of members |
| `.[]` | every child of an array, or every value of an object |
| `.a[]` | every child of a member |
| `.a[0]` | one element; a negative index counts from the end |
| `.a[1:3]` | a slice, which is itself an array |
| `.a[9]` | `null` when the index is out of range |
| `a \| b` | run `b` over each result of `a` |
| `a, b` | both results, in source order |
| `if c then a else b end` | `a` when `c` is truthy, `b` otherwise |
| `if c then a elif c2 then b end` | the first branch whose condition is truthy, left to right |

Builtins:

| Shape | Names |
|---|---|
| no argument | `length` `keys` `type` `not` `empty` `reverse` `sort` `unique` `add` `first` `last` `min` `max` `to_entries` `from_entries` `tostring` `tonumber` `ascii_downcase` `ascii_upcase` |
| one literal argument | `has("k")` `range(n)` `join("-")` `startswith("s")` `endswith("s")` `ltrimstr("s")` `test("re")` |
| one literal of any shape | `contains(x)` — a string, a number, an array, or an object |
| position of a value | `index(x)` `rindex(x)` `indices(x)` — over a string or an array; an object is refused |

### Exit Codes

| Code | Meaning |
|---|---|
| `0` | values printed |
| `1` | filter selected nothing |
| `2` | trouble: bad usage, unreadable file, malformed JSON, refused filter |
| `4` | with `-e` only: nothing was ever produced |

The `1` is **oojq's own contract, not jq's**. jq exits `0` when a filter selects
nothing; it only reports that under `-e`, and then it uses `4`. So oojq's default
distinguishes "found nothing" from "found something", which jq does not.

With `-e` oojq matches jq exactly, including the `4`:

| | last value `false` or `null` | nothing produced | values printed |
|---|---|---|---|
| `jq -e` | `1` | `4` | `0` |
| `oojq -e` | `1` | `4` | `0` |
| `jq` | `0` | `0` | `0` |
| `oojq` | `0` | `1` | `0` |

### Examples

```bash
# Read a field
oojq .name package.json

# Iterate an array, piped onward
oojq '.tags[] | .' openOODA-tools/oojq/README.md

# Union two paths, no quoting needed
oojq .a, .b config.json

# From a pipe
cat data.json | oojq '.items[]'

# Cut a string on a literal separator, streaming one value per piece
oojq '.log | split(" ")' app.log

# Percent-encode a value for a URL
oojq '.title | @uri' page.json

# Write a CSV file, one row per record
oojq -r '.rows[] | @csv' report.json

# Check every record, and answer nothing at all if one is missing its id
oojq -e 'all(has("id"))' rows.json
```

### Output

Spacing follows jq's default form, one value per line:

```
$ oojq . demo.json
{ "name": "oojq", "tags": [ "json", "cli" ], "meta": { "stars": 42 }, "note": null }

$ oojq .tags[] demo.json
"json"
"cli"
```

---

## 4. What Is Not Supported

Each is refused by name rather than silently approximated, because a narrowed
filter that returns a confident wrong answer is worse than a refusal.

- **The date builtins `now`, `localtime`, and `gmtime`-as-a-string are still
  refused.** `gmtime`, `mktime`, `todate`, `fromdate`, `fromdateiso8601`,
  `strftime`, and `strptime` are implemented (see *UTC dates* above); these are
  the rest.

- **Errors go to stdout, where jq puts them on stderr.** `oojq -c '2|sqrt' > out`
  writes the refusal *into* `out`, and `2>/dev/null` does not hide it. This is
  not a choice. The runtime exposes **no stderr writer**: `print` lowers to
  `@oo_print_str`, which writes to stdout with no trailing newline, and
  `eprintln` — although the compiler *knows* the name, in `tc_names_known.oo`
  and in the side-effect classifier in `ll_fn.oo` — has **no lowering at all**.
  There is no `@oo_eprintln` declaration in `ll_need_tab.oo` and no matching
  runtime symbol anywhere in the toolchain, so calling it would not write
  anywhere. The compiler is a parent project and out of bounds here, so the
  divergence is recorded and **asserted** rather than papered over: three
  assertions in `make test` pin the exact text on stdout, pin stderr to empty,
  and pin the version banner to stdout, so the day the runtime grows a stderr
  writer the suite says so instead of the docs quietly going stale.

- **Exit codes are oojq's own contract where jq's are finer.** jq distinguishes
  `2` for a usage or system error, `3` for a compile error, and `5` for a
  runtime error; oojq returns `2` for all of them, which is written down in
  `main.oo` and encoded in 47 assertions. Two of the three are already matched
  exactly: `-e` reports `4` for never having produced a value, and `--help` and
  `--version` exit 0. The remaining gap is deliberate and is not a defect, but
  it is the one place a shell script that branches on `$?` will see different
  behaviour from jq.

- **`add` with a filter.** `add` with no argument sums the members and is
  implemented. `add(f)` — jq's `[f] | add`, which runs the filter once over the
  whole input and sums every answer — is refused with that reason rather than
  answered with the member sum, which is a different number. See *Design Notes*.
- **Variable binding**: `as $x | ...`, `reduce`, `foreach`, and `def`. These
  need a named environment threaded through the evaluator. All of them, plus
  `try`, `label`, `import`, `include`, and `__loc__`, are refused *by their own
  name* rather than as an unknown builtin. That distinction was worth a fix: the
  page already had a function refusing all nine reserved words, and nothing called
  it, so `def` was answered *unknown builtin "def"; did you mean "del"?* — a
  suggestion pointing a reader at a builtin with one letter in common, on exactly
  the input where they had named a language construct. A reserved word is still
  an ordinary field name, so `.import` answers `1`.
- **Object construction is supported**, including `{}`, a bare name key, a quoted
  key, a key in brackets, the `{a}` shorthand, and a value written as a
  generator. `{a: (1,2), b: (3,4)}` answers four objects in jq's order, and an
  entry that answers nothing leaves no object at all. It is not a rule in the
  run: `{a: X, b: Y}` is rewritten at parse time into a call over the body
  `[[X], ["a"], [Y], ["b"]]`, so the entries are already gathered by a collect
  and the product comes from multiplying them. `{1: 2}`, `{.k: .v}`, and
  `{("a")}` are refused by name, because jq reads all three as syntax errors and
  answering them would build an object nobody wrote. The `+` merge of two
  objects also works, and keeps the left hand side's order while a right hand
  side member replaces the one it shares a name with, so `.limits + .limits` is
  byte identical to jq.
- **`setpath(p; v)` is supported, and it is the whole of what it supports.** Both
  sides are read before anything is written and the body is rewritten at parse time
  to `[[P], [v]]`, so each side arrives already gathered and a generator on either
  one multiplies exactly as it does in jq: `setpath(["a"]; 1, 2)` answers both
  objects, and `setpath(["a"]; empty)` answers nothing rather than a null. A member
  keeps the position it was first given and a member that was not there is
  appended; an array position is replaced, a negative position counts back from the
  end, and a position past the end grows the array with nulls. A null with path
  still to walk becomes whatever the next step names, so `setpath([0]; 1)` on
  `null` is `[1]` and `setpath(["x","y"]; 1)` on `{"a":1}` is
  `{"a":1,"x":{"y":1}}`. The refusals are jq's sentences rather than this tree's:
  a name into an array says `Cannot index array with string "a"`, a numeric key is
  named by its kind and not its digits (`Cannot index object with number`), a
  position before the start of an array says `Out of bounds negative array index`,
  a path that is not an array says `Path must be specified as an array`, and the
  wrong number of arguments names the arity (`setpath/1 is not defined`).
- **The update operators are supported, and they are not one feature.** `=`, `|=`,
  `+=`, `-=`, `*=`, `/=` and `%=` all work on a literal path, and they are three
  different features wearing one operator table. Measured against jq 1.8.1
  before any of them was written, because none of it is derivable from the
  spelling:
  - `.a = v` is exactly `setpath(P; v)`, empty value and all: `.a = (1,2)` gives
    two objects and `.a = empty` gives nothing.
  - `.a |= f` keeps only the **first** answer of `getpath(P) | f` (`.a |= (1,2)`
    is one object), and when the body answers nothing it **cuts the key**:
    `.a |= empty` on `{"a":1,"b":2}` is `{"b":2}`, where `.a = empty` is nothing.
  - `.a += v` and the rest keep **every** answer (`.a += (1,2)` gives
    `{"a":2,...}` and `{"a":3,...}`) and answer **nothing** when the body does,
    with no cutting branch: `.a += empty` is nothing where `.a |= empty` is
    `{"b":2}`.

  All of it is a parse-time rewrite onto `setpath`, `getpath`, and the `del` that
  already existed, which is why **the run needed no line at all** for any of it.
  A path in parentheses is still a path, so `(.a) |= .+1` answers, and an
  operator written tight (`.a-=1`) is still an operator while `.a + 1` is still
  a sum. The refusals are jq's sentences: an assignment through a scalar says
  `Cannot index number with string "b"`, and so does an update through one.
  **What is refused:** `//=`, by name, because jq reads its right hand side
  eagerly — `.a //= empty` answers nothing where `.a // 9` would not, and
  `.a //= error("x")` raises on a value where `x` is truthy. That is not a
  filter this build can hand over, and an operator that answered something else
  would be a wrong answer. A path naming two members, `(.a,.b) = 7`, is refused
  for the same reason: it needs `reduce` over `path()`, not a literal path.
- **`walk`,** and the other builtins that take a filter rather than a literal.
  `getpath`, `range`, `limit`, `with_entries`, `recurse`, and `walk` are the
  exceptions. `walk(f)` applies `f` at every node with the value in hand **last**:
  a container is rebuilt from its walked children and `f` is applied to what was
  rebuilt, which is why `[[1]] | [walk(if .==[1] then "saw" else . end)]` answers
  `["saw"]` and not `[[1]]`. A child that answers nothing is dropped and takes its
  key with it, so `{"a":1,"b":2} | [walk(if .==1 then empty else . end)]` is
  `[{"b":2}]` while a body that answers twice keeps both, and
  `1 | [walk(if .==1 then 7,8 else . end)]` is `[7,8]`. Unlike every other
  filter-argument builtin it keeps **every** answer of its body rather than the
  last. All twenty-two cases measured against jq 1.8.1 are byte-identical. It is
  answered by regenerating one level as text and handing that back to the same
  dispatcher, which is where its recursion comes from — see AGENTS.md for why the
  recursion cannot live in the text itself, and why the object form updates
  `.value` rather than walking the entry.
  `recurse(f)` applies `f` at every level and answers in preorder — the value in
  hand, then what `f` gives from it, and for each of those the same again — so
  `[[1],[2]] | [recurse(.[]?)]` is `[[[1],[2]],[1],1,[2],2]` and not the
  breadth-first `[[[1],[2]],[1],[2],1,2]`. `f` answering nothing ends that branch,
  an error is **not** caught (jq does not catch it either; the bare `recurse` is
  safe only because it is written `.[]?`), and a fixed point does not terminate,
  so `1 | recurse(1)` runs forever exactly as in jq. `recurse(f; cond)` is
  `recurse(f | select(cond))` — measured, both answer `[1,2,4,8,16]` for
  `1 | recurse(.*2; . < 20)` — so it is a parse-time rewrite of the argument
  rather than a second walk. A bare `recurse` means `recurse(.[]?)`. The
  `limit(n; f)` rewrite is collect, slice, iterate — so it costs the evaluator
  nothing and every case jq answers byte for byte matches, including `limit(0; …)`
  answering nothing and a count past the end keeping all of them. **Its one
  difference is the count:** jq reads `limit(.a; f)` at run time, while a slice
  bound here is fixed while the filter is parsed, so a count that is not digits
  written in the filter is refused by name. Running the body without one would
  answer with every value it produced, which is a plausible wrong answer.
  `with_entries(f)` is the same kind of rewrite: it is
  `to_entries | map(f) | from_entries`, checked against jq 1.8.1 on a value
  update, a key update, and a `select`, and the two spellings are byte identical
  both ways, including an array refusing with the same *"Cannot use number (0) as
  object key"* because the index is a number and `from_entries` will not make it
  a name. Its bodies are limited to what this build can already write, so the
  usual `.value += 1` still needs the update operators below.
- **`map_values` on a value that is not a container, and a bare `map_values`.**
  `map_values(f)` is otherwise answered in full: it is the **first** answer of `f`
  at every member, keeping the shape it was given, so `{"a":1,"b":2} |
  map_values(1,2)` is `{"a":1,"b":1}` and not what `map` would do — `map` gathers
  every answer, and `[1,2] | map(1,2)` is `[1,2,1,2]`. A member that answers
  nothing is dropped and takes its key with it. Both shapes are answered by a
  parse-time rewrite to `to_entries | map(.value |= (f)) | map(select(has("value")))
  | map(.value)` over an array and the same text into `from_entries` over an
  object, which is the one route here to "first answer, dropped on empty" over
  both — the rewrite costs the evaluator nothing, and 17 of 21 probed cases are
  byte-identical to jq 1.8.1. The remaining four are refusal **wording**, not
  wrong answers: a number, a string and a null say *"to_entries needs an array or
  object, not a …"* where jq says *"Cannot iterate over number (1)"*, and a bare
  `map_values` is *"unknown builtin"* where jq says *"map_values/0 is not
  defined"*. Both forms refuse, which is the point; matching the wording would
  cost the hub a line it does not have.
- **`from_entries` on an entry that is not shaped the way it is read.** The name
  and value are read from four and two spellings respectively, in an order that
  is measured rather than taken from the manual: `key` beats `Key` beats `name`
  beats `Name`, and `value` beats `Value`, while `k`, `v`, `val` and `KEY` are
  not read at all — so `[{"k":"a","v":1}] | from_entries` is not `{"a":1}`, it is
  the refusal *"Cannot use null (null) as object key"*, which is also what an
  entry with no key at all gives. A member that kept its key and lost its value
  reads as **null**, matching jq; it used to answer nothing at all, which is the
  exact shape `walk(f)` hands `from_entries` when a child answers empty, so one
  dropped key of two dropped the whole object. A key that is not a string is
  refused by kind and by value (*"Cannot use boolean (true) as object key"*), and
  a non-object entry is refused the way jq indexes it (*"Cannot index number with
  string \"key\""*). All sixteen cases probed are message-identical to jq 1.8.1.
- **`splits`, `sub`, and `gsub`, and `test` on a pattern the std engine cannot
  honour.** These are refused by name. The reason for the first three is a
  defect in the std regex engine, not a missing parser: `match_pattern_first`,
  which all three are built on, calls `str_slice` one index past the end of the
  string, so a pattern that does not match reads off the buffer and the process
  dies on a signal. `"abc" | sub("z"; "y")` crashes rather than answering. For
  `test` the defect is quieter and was worse: the NFA reads a pattern one
  character at a time and has no escape, group, counted repetition, class range,
  or negated class, while the validator accepts all of them as well formed. So
  `test("a\\.c")`, `test("(ab)c")`, `test("a{1}")`, `test("a\\d")`,
  `test("[a-z]")`, `test("[^a]")`, and `test("[A-Z]")` each answered a confident
  `false` where jq answers `true`. A `false` from `test` drops the rows it was
  meant to keep, so each is now refused by the name of the construct it uses.
  Literals, `.`, `*`, `+`, `?`, `|`, `^`, `$`, and a plain `[abc]` still work,
  and `split` is literal, so the common cases are covered.
- **`paths(f)` and `leaf_paths(f)`.** The bare forms work. The filter form is
  refused by name rather than answered with every path, which is what it used to
  do: `[paths(.=="a")]|length` was 16 where jq gives 2.
- **`fromjson?`** — the bare `fromjson` works, and its answer is copied into the
  arena the caller keeps, but `fromjson?` needs a `parse_prim` marker for the
  bare form.
- **`$__loc__`, `input`, `inputs`,** and every other environment or input
  source builtin.
- **`tostream`, `fromstream`, `todate`, and `fromdate`.**
  `indices` used to be on this list and is **now implemented** — see *Where a
  value appears* below. Where a builtin takes a generator where this build's
  argument path carries one, the call **refuses** instead: `index`, `rindex`,
  `indices`, `contains` and `error` answer *"… takes one value, and the argument
  written gives several"*, which is where `[1,2] | index(1,2)` used to answer
  `1` where jq answers `0` then `1`.
  `setpath` is deliberately left out of that refusal: it takes a generator on
  purpose and answers once per value. `toarray` and `ascii` are deliberately
  **not** here: jq
  1.8.1 does not have them either, and matching a builtin that does not exist
  is not parity.
- **`in` and `combinations`,** both of which jq 1.8.1 itself is broken on. `in`
  is a syntax error in jq 1.8.1 for the form it is written in
  (`. as $o | "a" in $o` does not parse), and `combinations` is implemented in
  terms of `in`, so `[1,2] | combinations` errors with `Cannot iterate over
  number (1)` while `[[1],[2]] | combinations` works. Matching a builtin whose
  own reference behaviour depends on a broken one would mean copying the
  breakage, so neither is built. `combinations(n)` does work in jq and is the
  only part worth having; it is not built yet.
- **Division whose quotient does not terminate**, and arithmetic over a number too
  wide for a whole number to hold. `1/3` has no exact decimal form at all, so it
  is refused rather than rounded, and `1.5/8080` is refused for the same reason
  where jq prints seventeen digits of a double. Everything that terminates is
  answered exactly: `10/4` is `2.5`, `1/8` is `0.125`, `1.5/0.5` is `3`,
  `0.5/0.25` is `2`, and `1/0.0001` is `10000`. Both sides are lifted to whole
  numbers over the same power of ten first, so a decimal divides by exactly the
  same long division a whole number does. Seventeen fraction places and
  seventeen or eighteen digits is the widest this will name, and anything wider
  is refused rather than wrapped.
- **`if` without an `else`.** jq treats a missing `else` as `null`; this build
  requires the branch.

Float arithmetic works, and it is exact. The compiler bug that blocks
`to_string` on a `Float` is still real and is recorded below, but it is worked
around by carrying numbers as decimal text and folding the digits, so `1.5 + 1`
is exactly `2.5`, `floor`, `ceil`, `round`, and `abs` all work, and `*` and `/`
work on decimals rather than only on whole numbers.

`sqrt` is the one arithmetic builtin with a boundary rather than a yes or a no,
and the boundary is drawn where it can be drawn exactly. A square has an exact
root and oojq gives it: `4|sqrt` is `2`, `0.25|sqrt` is `0.5`, `1000000|sqrt` is
`1000`, and a whole root prints as a whole because that is how jq prints it. A
negative has no real root, so `-4|sqrt` is `null`, which is jq's answer and not a
refusal.

Everything else is **refused by name** rather than rounded. jq answers `2|sqrt`
with `1.4142135623730951` — the shortest text that names the IEEE double it
computed — and that is a different thing from the exact root, which has no
finite decimal spelling at all. Producing it would need the double itself, and
this build has no way to hold one. Printing a rounded root as though it were
exact is precisely the confident wrong answer the rest of this document refuses
to give, so `2|sqrt` says why it cannot and stops. The same applies past
eighteen digits, where the whole root no longer fits.

---

## 5. Design Notes

`AGENTS.md` is the real document: house laws, domain contracts, and the runtime
traps that cost debugging time. These are the ones worth knowing before editing:

- **A string operation checks its operands, and getting that wrong is a wrong
  answer rather than a gap.** Nine builtins read a string out of their argument
  — `index`, `rindex`, `indices`, `split`, `startswith`, `endswith`,
  `ltrimstr`, `rtrimstr`, `test` — and each had a path where it coerced the
  wrong kind instead of refusing: `"abc" | index(1)` answered `null`,
  `null | startswith("a")` answered `false`, `1 | split("b")` answered `[""]`.
  All eight are now refused, in **jq's own words**, by one guard in
  `filter/eval/eval_builtin.oo` because the shape is identical and only the
  wording differs. The guard runs *before* the generic "needs a scalar literal
  argument" check, so `"abc" | startswith(null)` says `startswith() requires
  string inputs` rather than the vaguer sentence. `ltrimstr` borrows
  `startswith`'s sentence and `rtrimstr` borrows `endswith`'s, because that is
  what jq does — it builds one from the other. The lesson generalises: **an
  answer produced for a shape the author did not think about is a wrong
  answer, and a kind check is the cheapest test there is.**
- **`""|split("b")` is `[]` and not `[""]`.** The empty string has no pieces
  once the separator is not itself empty, so the trailing-piece step that makes
  `"a" | split("a")` give `["",""]` must not run at all. Found by accident, by
  writing a probe whose pipe changed the input to the builtin under test.
- **A kind matrix finds what a corpus cannot.** Running every dispatched builtin
  against every kind of input and every kind of scalar argument — 1 504 agree, and
  of the 893 that differ, 2 113 more are refusals on both sides differing only in
  wording — left **29 cases where both binaries answer and the answers differ**.
  Those are the only ones that matter, and two families came out: **`add(f)`
  dropped its filter and summed the members instead** (`[1,2] | add(.)` is
  `[1,2]` in jq and was `3`), and **`index` over a `null` accepted a needle it
  should refuse**. Both are fixed. The matrix is at `/tmp/kinds.sh`; the
  discipline is that **a value produced for a shape nobody thought about is a
  wrong answer, and the cheapest way to find those is to cross the kinds rather
  than to enumerate more examples.**
- **`add(f)` is `[f] | add`, not a member sum, and is refused rather than
  guessed.** jq runs the filter **once over the whole input** and sums every
  answer, which is why `[1,2,3] | add(.)` is `[1,2,3]` and
  `[[1,2],[3]] | add(length)` is `2`. Summing the members gives a different
  number, so the call now refuses with the reason. The machinery to do it
  properly already exists — collect mode runs a body over the input and gathers
  every answer — but the page that would finalise it is at the 256-line ceiling
  and its directory at the 8-page density limit, so it is backlog rather than a
  rushed change.
- **Numbers.** std reports a number as the byte offset past its last digit and
  never materialises the digits. `parse/decode_number.oo` is the only place a
  literal becomes an `Int`, and `parse/float_scan.oo` hides decimal points from
  the scanner by rewriting each float to digits of the same width, which keeps
  every byte offset valid. A float keeps its source text, so parse and render
  round trip losslessly.
- **No Float to String.** `oodac/emit/llvm/ll_builtin_host.oo:220` routes
  `to_string` to `oo_int_to_str` for every argument type, so `to_string(1.5)`
  emits `oo_int_to_str(i64 1.5)` and fails at the LLVM stage. The runtime has no
  `double`-to-string function either. oojq therefore never puts a `Float` in the
  arena: `filter/eval/num_read.oo` and `eval_num.oo` carry a number as its
  decimal text and fold the digits, which is exact where a `Float` would round.
- **Escaping.** `std/core/format/json_writer.oo` is a complete fluent encoder,
  but its escaper leaves every control byte below `0x20` unescaped apart from
  three. `render/render_string.oo` covers the full set, and escapes `0x7f` and
  anything above it as `\uXXXX` so output stays valid UTF-8.
- **Text is characters, but `byte_at` is bytes.** `chars_len` counts characters
  while `byte_at` indexes bytes, so a loop that pairs them walks off the end of
  any multi-byte string. The renderer did exactly that and printed `"héllo"` as
  `"h\u00c3\u00a9ll"`. Both now walk characters with `char_at` and copy a
  multi-byte one through whole.
- **The std JSON reader refuses `\uXXXX`.** It reports `bad_escape` and stops.
  `parse/unescape_unicode.oo` therefore rewrites every escape into the UTF-8
  bytes it stands for before the reader sees the document, joining a surrogate
  pair into the one code point it denotes and standing a lone surrogate in as
  `U+FFFD`. It hands back a byte buffer rather than a string, because reading
  those bytes back out of a string would lose every one after the first
  multi-byte character.
- **Determinism.** The arena is append-only and object member order is preserved
  as parsed, so two runs over identical input produce identical bytes. `make
  test` asserts this.
- **An object never holds a name twice.** jq keeps the position a name was first
  written in and the value it was last given, which is what a merge does and what
  a source saying `{"a":1,"a":2}` means. The parser and `from_entries` each used
  to keep both copies, so one name read as two: `keys` answered `["a","a"]`,
  `length` answered 2, and `to_entries` invented a member that was never written.
  The reason it survived is worth keeping: `.a` answered `2` on both binaries,
  because last-write-wins *is* what a lookup does. Only the questions that read
  the container as a whole found it. The rule now lives in `put_member` in
  `parse/value_tree.oo` and is enforced by `jval_object`, which every way of
  building an object passes through.
- **A document of more than a few hundred members is slow, and the cause is the
  language rather than the filter.** This is the one measured place oojq is far
  worse than jq, so it is worth being exact about why. In openOODA a `List`
  append returns a new list: `list_push` copies. There is no growable buffer in
  the language, and the std collections that look like one are not — `pvec_push`
  in `persistent_vector.oo` rebuilds its whole element list, and `fhm_insert` in
  `flat_hash_map.oo` goes through a `list_set_str` that rebuilds the key list. So
  `jdoc_push`, which appends one node to the arena's list, is O(n) per push and
  an *n*-node arena is O(n²) by construction, and nothing in the filter language
  can work around it. Measured on this build, `length` over a document of *n*
  members, where jq answers every one of these in under 0.01s:

  | n | oojq object | oojq array |
  |---|---|---|
  | 250 | 0.01s | <0.01s |
  | 500 | 0.05s | 0.01s |
  | 1000 | 0.19s | 0.04s |
  | 2000 | 1.17s | 0.16s |
  | 3000 | 3.21s | 0.41s |

  The two are quadratic and the object is about seven times the array at the same
  size, because `jval_object` enforces the no-duplicate-name rule with a second
  quadratic pass over the keys. The two are indistinguishable from jq up to about
  a hundred members, which is most documents anyone writes by hand; the crossover
  into "noticeable" is around 250. **This is a representation limit, not a filter
  limit, and the honest fix is a non-copying arena rather than a cleverer walk.**
  What is *not* done here is a fast path that scans for a duplicate name before
  rebuilding: it would cut the constant and leave the asymptotics exactly where
  they are, in the single most-used function in the tree, and a silent miscompile
  there is not a trade worth making for a constant.
- **`@format` is `tostring` plus a transform, and `tostring` is not scalar-only.**
  jq writes a container as the same compact JSON it would print, so `render_as_text`
  in `render/render_value.oo` answers every node kind and `@text`, `@html`, and
  `@uri` all build on it. Refusing a non-string would be refusing something jq
  answers: `1|@html` is `"1"`.

### Layout

```
main.oo          argv routing, the exit-code contract, the pipeline
parse/           JSON text -> value tree (arena of nodes plus a root index)
filter/          filter text -> value stream
render/          value stream -> JSON text
ipc/             file and stdin reader today; MCP and socket later
```

---

## 6. Verification & Governance

All code adheres to the openOODA House Laws documented in [`AGENTS.md`](AGENTS.md):

- **Page Rule**: Every source page strictly bounded between 16 and 256 lines, at
  most 8 per directory.
- **Academy Headers**: Mandatory 4-element docstrings on every page, all four
  elements inside the first 7 lines.
- **Zero-Panic Invariant**: Robust error propagation without unvetted crashes.
- **Exit Code Law**: `0` values, `1` nothing selected, `2` trouble.
- **File Law**: Clean tree with no forbidden file extensions or stray docs.

### How the answers are checked

There are three oracles, and they fail differently on purpose.

| | what it asks | what it cannot see |
|---|---|---|
| `make test` | does each named behaviour still hold | any input nobody wrote a test for |
| `make parity` | is this one output byte-identical to jq | a filter the corpus does not mention |
| `make sweep` | is a corpus-*blind* probe byte-identical to jq | nothing — that is the point |

`parity` and `sweep` draw on different corpora on purpose. The parity corpus only
grows where a divergence was already found, so it confirms and never discovers.
The sweep corpus in `qa/sweep_cases.txt` is deliberately disjoint from it, and it
is the only layer that can find a class of input nobody thought of. Two real
bugs came out of its first run: `max` compared with `>` and so kept the earlier
of two equal values, and an `if` branch was handed the condition's answer instead
of the value the condition was asked of.

Two rules are built into how the sweep runs, both learned by breaking them:

- **Comparison is `cmp` on files, never `$(...)`.** Command substitution drops
  NUL bytes from both sides, so a value holding one would compare equal to a
  value that is simply absent.
- **A reference run is never truncated.** Piping `jq` into `head -1` on a filter
  that answers several times hides the shape of the answer, and it is how this
  project briefly came to believe that an `if` reads only its first answer. Every
  divergence is printed in full.

`make dead-tests` fails when two assertions share a name. It was written because
three did, and each was a continuation of the sentence before it — "and not above
it", "and the same the other way round" — which is what a name becomes when
nobody can say which assertion failed. A name has to stand on its own.

`make coverage` prints, per dispatched builtin, how many behaviour assertions and
how many parity cases name it. It is not coverage and does not claim to be — it
cannot tell a test that exercises a builtin from one that mentions the word. What
it catches is the failure that actually happened: a builtin no test reaches at
all, which prints `0 0`. `leaf_paths` printed `0` and had been shipping untested,
and no other gate noticed. Two columns because the two oracles differ —
`booleans` and `objects` are reached by parity alone.

Assertions that assert *nothing was written* use `assert_bytes`, not
`assert_out`. Command substitution strips trailing newlines, so `assert_out`
cannot tell one empty line from no output at all, and a test written that way
passes even when the program writes nothing. Counting bytes on stdout does tell
them apart.

**Not covered:** there are no fuzz, property, or performance tests, and no
mechanism yet for retiring a test that no longer protects anything. `parity` and
`sweep` are deliberately outside `verify`, so the byte-diff against real jq is
not part of the green gate.
