# Concurrent script evaluation in the Leios voting loop

This note describes the change on this branch, what the bench next to it
measured, and why the change is kept as an option rather than proposed with
the loop fix. The first section names the three loops compared and the
closures the bench builds. The second reads the bench, whole closures first.
The third asks what the most expensive closure is under the caps and
without them, and projects it onto the testnet's hosts. The last two
sections say when the change is needed and what stays sequential.

## The three loops and the closures

During the voting phase, the node runs a loop over an EB's closure,
transaction by transaction, applying the transactions it has not seen and
reapplying the ones its mempool already validated. The loop starts
once the closure has arrived, and not before three seconds after the
announcement; the vote is due at seven. A closure that arrives by the third
second leaves four seconds for validation, one that arrives later leaves
less, so a faster validation is what admits a late closure.

Today's loop, the one the `leios-prototype` tip and the w45 node run, keeps
the closure's whole input table inside the ledger state and converts it out
and back after every applied transaction. Its cost per applied transaction
grows with the closure.

The loop fix, the first commit on this branch, keeps the table outside the
ledger state and runs each transaction on a state holding its own inputs.
Its cost per applied transaction is flat in the closure.

This branch's commit adds a concurrent pre-pass to the fixed loop. Before
applying, it judges the scripts of every transaction to be applied on 64
threads, each taking a slice of the closure, against the inputs the table
holds for it. It then applies the transactions in order with the ledger's
two-phase clause, the part of the rule that runs Plutus scripts, switched
off where the judgement agreed with the transaction's validity flag, and
with the full application otherwise. Signatures and every other check stay
in the sequential pass.

The bench builds closures of four kinds. An old-input closure is one whose
transactions spend outputs that were in the ledger before the closure, the
kind the testnet's centrifuge generates. A chained closure is one in which
each transaction spends the previous transaction's output, so the closure's
input table holds only the first inputs, the kind the firehose generates. A
script closure's transactions each spend an output locked by a Plutus V3
script whose work is a parameter, so their steps are chosen. A heavy
closure's transactions spend one output of each of 91 keys and one script
output, the shape of the testnet's 2026-11-02 stress test, 16 kB each. The
script and heavy closures are old-input closures too: every output they
spend was in the ledger before the closure, so today's loop pays its table
pass on them as it does on the centrifuge's.

## What the bench measured

The bench is `leios-voting-bench` in this folder, run on an Apple M4 Max
laptop with nothing else running. It validates each closure twice against
one transaction cache, so the first pass applies every transaction and the
second reapplies every one, and reports the best of three runs.
Capabilities are the threads the runtime may run at once, the node's `-N`
setting; the two sequential loops ignore it.

Whole closures are the right unit, because today's cost per transaction
depends on the closure around it. The table sums the apply pass over
closures of one shape.

| closure of one shape; seconds to apply all | today | loop fix | fix and pre-pass,<br>2 capabilities | 4 | 8 |
|---|---:|---:|---:|---:|---:|
| 6,000 old-input value transfers, 1.16 MB (the centrifuge's kind) | 6.80 | 0.49 | 0.50 | 0.49 | 0.50 |
| 6,000 chained value transfers, 1.16 MB (the firehose's kind) | 0.46 | 0.47 | 0.53 | 0.48 | 0.49 |
| 100 transactions of 91 keys, no script, 1.6 MB | 0.47 | 0.25 | 0.26 | 0.24 | 0.25 |
| 100 transactions of the stress shape, 91 keys and 9.7 Gsteps, 1.6 MB | 0.94 | 0.73 | 0.51 | 0.39 | 0.35 |
| 208 script transactions, 2,080 Gsteps, 0.07 MB | 0.94 | 0.97 | 0.53 | 0.31 | 0.19 |
| 751 script transactions, 7,500 Gsteps, 0.25 MB | 3.49 | 3.40 | 1.86 | 1.08 | 0.66 |

The value closures take everything from the fix and nothing from the
pre-pass. The old-input closure drops from 6.8 seconds to half a second at
the fix and stays there in every capability column; the chained one, which
never paid the table pass, reads half a second throughout.

The script closures are the ones the capabilities move, and the stress
shape, half scripts and half signatures, moves by half: the 751-script
closure goes from 3.4 seconds on the fixed loop to 0.66 on eight
capabilities, five times less, and the stress closure from 0.73 to 0.35.

The per-transaction figures explain the whole-closure ones: flat columns
for the loops with the fix, a growing one for today's.

| shape (1,000-transaction closures, 100 for the heavy ones); microseconds per applied transaction | today | loop fix | fix and pre-pass,<br>2 capabilities | 4 | 8 |
|---|---:|---:|---:|---:|---:|
| value transfer, one input | 229 | 80 | 80 | 81 | 84 |
| old-input value transfer, 5,000-transaction closure | 883 | 84 | 83 | 82 | 84 |
| chained value transfer, 5,000-transaction closure | 77 | 80 | 88 | 80 | 82 |
| script transaction, no budget | 265 | 115 | 113 | 112 | 114 |
| script transaction, 0.7 Gsteps | 605 | 458 | 286 | 215 | 172 |
| script transaction, 2.1 Gsteps | 1,275 | 1,113 | 622 | 406 | 292 |
| script transaction, 6.9 Gsteps | 3,409 | 3,288 | 1,777 | 1,053 | 646 |
| heavy, 91 keys, no script | 4,661 | 2,544 | 2,589 | 2,426 | 2,510 |
| heavy, 91 keys and 9.7 Gsteps (the stress shape) | 9,413 | 7,332 | 5,140 | 3,905 | 3,467 |
| reapply, any shape | 39 | 45 | 46 | 49 | 50 |

Scripts scale with the capabilities, 1.8 times at two, 3.1 at four and 5.1
at eight on the 6.9 Gstep row; the other script rows repeat the pattern.
Nothing else moves: the 91-key transaction without a script reads the same
in every column after the fix, because the pre-pass evaluates scripts only.

Transactions without scripts pay nothing for the pre-pass. The value and
reapply rows sit within run-to-run noise of the fixed loop up to four
capabilities; the five microseconds they gain at eight are the runtime's
parallel garbage collector, which the `-qg` option removes.

The speedup depends on the capability count alone, not on the pre-pass's
own thread count: with 2, 4, 8 or 64 threads at a given capability count
the figures read within two percent of each other, so the change has no
parameter to tune, and the cores set the gain. What holds the
eight-capability column back from the ideal is the
sequential floor, 115 microseconds per transaction for the rule without
scripts, and eight cores sharing memory bandwidth at an allocation rate of
nine gigabytes per second.

The per-transaction figures also predict whole closures, which is what
the rest of this note relies on. Subtracting the 115-microsecond floor
from the 6.9 Gstep row gives a cost per Gstep at each capability count,
460 microseconds on the fixed loop, 241 at two, 136 at four and 77 at
eight; a closure's time is then its transactions times the floor plus its
steps times that rate. For the 751 scripts of 7,500 Gsteps this predicts
3.54, 1.89, 1.11 and 0.66 seconds against the measured 3.40, 1.86, 1.08
and 0.66, and the 208-script closure comes out as close. Every figure
predicted below was checked the same way, and the prediction held within
four percent.

## The most expensive closure

A voter's time is the sum of its closure's transaction costs, so the
costliest closure is the one that packs the most cost under the caps. The
caps are four at the EB level, payload bytes, reference-list bytes, steps
and memory, and three per transaction, 10 Gsteps, 16.5 million memory units
and 16 kB.

The per-transaction caps are mainnet's and stay fixed throughout: a
transaction in an EB is the same transaction an RB carries, under the same
limits, so only the EB-level caps scale with the closure.

The closure size used throughout this section is 1.62 MB, ten times
Praos's byte ceiling at the ladder's parameter ceiling; the testnet's cap
today is 2 MB, and every figure below scales with the bytes. Where the step
cap is scaled or lifted the memory cap goes with it: memory units are a
budget tally, not a time, and bind only what fits in a transaction.

Two of the caps can bind, the steps and the payload bytes: the
reference-list cap admits more transactions than the payload cap does at
every shape, and the memory cap follows the step cap at these shapes. From
the bench, a transaction costs about 80 microseconds fixed, 5 per extra
input, 27 per extra signing key with its input and output, 30 per script
and 450 per Gstep. A Gstep costs the same wherever it sits, so a binding
step cap adds a fixed 450 microseconds per Gstep whatever the closure;
what the composition changes is the cost per byte. A script at the
per-transaction cap costs thirteen microseconds per byte, ten Gsteps in
339 bytes; the smallest value transfer, 193 bytes, 0.4; an extra signing
key with its bytes 0.14.

If we assume no EB step and memory caps and let the bytes bind, the
costliest closure is all scripts at the per-transaction cap, the bytes
divided by 339: in 1.62 MB, 4,779 transactions and 47,740 Gsteps.

With an EB step cap in place, the closure's scripts can use at most that
many steps in total. Spending them on transactions at the per-transaction
cap takes the fewest bytes, and the bytes left over are then best filled
with the smallest transfers, the densest fixed cost per byte. With caps proportional to mainnet's block,
232 Gsteps per megabyte of closure, the 1.62 MB closure holds 36 scripts
at the cap and 8,393 transfers. The testnet's 2026-11-04 proposal, 600
Gsteps per 2 MB closure, is taken at its own size: 60 scripts at the cap
and the 10,257 transfers that fill 2 MB.

| the costliest closure; seconds to apply all | today | loop fix | fix and pre-pass,<br>2 capabilities | 4 | 8 |
|---|---:|---:|---:|---:|---:|
| 1.62 MB under mainnet-proportional caps: 8,393 transfers and 36 scripts at the cap, 360 Gsteps | 13.9 | 0.89 | 0.81 | 0.77 | 0.75 |
| 1.62 MB, the same 360 Gsteps spread evenly: 4,779 scripts at 75 Msteps, no transfers | 4.5 | 0.72 | 0.63 | 0.60 | 0.59 |
| 2 MB under the testnet proposal: 10,257 transfers and 60 scripts at the cap, 600 Gsteps | 23.5 | 1.13 | 1.00 | 0.97 | 0.97 |
| 1.62 MB with the EB step and memory caps lifted, the per-transaction caps alone: 4,779 scripts at the cap, 47,740 Gsteps | 26.3 | 21.6 | 12.0 | 6.9 | 4.3 |

Under either EB step cap, the loop fix is what brings the closure within
reach: today's loop takes fourteen and twenty-three seconds, the fixed one
about one. The pre-pass then gains a tenth at most, because the scripts
are a fifth of that second or less and the transfers, the rest of it, are
sequential rule work it cannot touch.

With the EB caps lifted the bytes alone admit 47,740 Gsteps, and no
capability count brings that closure under the four seconds a closure
arriving by the third second leaves, let alone admits a later one. The
figure is also out of all proportion: a mainnet block carries 20 Gsteps in
90,112 bytes, so this closure holds eighteen blocks' worth of bytes and
2,387 blocks' worth of steps. The per-transaction cap does not bound a
closure; the EB cap has to.

The EB step cap is then a choice of how much time a voter may spend on
the costliest closure, and the pre-pass sets what that time buys. For a
cap of G Gsteps the costliest closure holds G/10 scripts at the
per-transaction cap and transfers in every other byte, so its time is the
transfers' time for the whole closure plus, per Gstep, the script's cost
less the transfer cost its 34 bytes displace: 437 microseconds per Gstep
on the fixed loop, 236 at two capabilities, 130 at four and 74 at eight.
A closure of transfers alone takes 0.72 seconds at 1.62 MB and 0.85 at
2 MB on the fixed loop, so a budget below that admits no scripts at all,
and a budget above it admits the cap the table gives. The first row of
each size spends the whole four seconds on validation and admits no
closure arriving after the third second; each row below it admits
arrivals that much later.

One caveat applies to every figure read against the window. The bench
times the loop alone, with the transactions already decoded and their
inputs in hand. On a node the vote also pays for deserialising the
closure's bytes, reading the inputs from the ledger database, ticking the
ledger state to the EB's slot, forming and signing the vote, and for every
other thread the node runs at the same time, the garbage collector among
them. Each cap in the table is therefore what the loop's share of the
window admits, an upper bound the integrated path can only lower, and
what that path costs on a deployed voter is what the testnet and cluster
readings are for.

| step cap the time budget admits, Gsteps | loop fix | fix and pre-pass,<br>2 capabilities | 4 | 8 |
|---|---:|---:|---:|---:|
| 1.62 MB, 4 seconds, arrival by the third second | 7,500 | 13,900 | 25,300 | 44,100 |
| 1.62 MB, 2 seconds | 2,930 | 5,420 | 9,850 | 17,200 |
| 1.62 MB, 1 second | 640 | 1,190 | 2,160 | 3,770 |
| 2 MB, 4 seconds, arrival by the third second | 7,210 | 13,300 | 24,300 | 42,400 |
| 2 MB, 2 seconds | 2,630 | 4,870 | 8,850 | 15,500 |
| 2 MB, 1 second | 340 | 640 | 1,150 | 2,020 |

Today's loop does not reach the table: its transfers alone take 13.8
seconds at 1.62 MB and 23.2 at 2 MB, and the closure of transfers it
validates in four seconds is 4,730 transactions, 0.91 MB, in two seconds
3,340, 0.65 MB, and in one 2,340, 0.45 MB.

Two of the table's cells were built as closures and timed as a check. On
the fixed loop, the two-second cap for 1.62 MB, 2,930 Gsteps, is a
closure of 293 scripts at the per-transaction cap and 7,879 transfers; it
took 1.97 seconds. At four capabilities the same budget admits 9,850
Gsteps, a closure of 985 scripts and 6,663 transfers; it also took 1.97
seconds.

### The testnet's hosts

The figures above are the laptop's. The table below projects them onto
the testnet's three host generations and is to be measured, not taken as
measured. Each generation applies transactions slower than the laptop by
a factor measured on the testnet's value transactions against this bench:
2.3 for the current generation, 3.9 and 4.3 for the two older ones. The
table scales the laptop's times by that factor, gives the loop the whole
four-second budget under the caveat above, and its eight-capability
column is optimistic on hosts with four cores and hyperthreads. The
transfers alone take 1.7 and 2.0 seconds on the current generation for
the two closure sizes, 2.8 and 3.3 two generations back, and 3.1 and 3.7
three; where that floor exceeds the budget the table reads "none".

| host generation and closure | step cap admitted in 4 seconds,<br>1 capability | 2 | 4 | 8 |
|---|---:|---:|---:|---:|
| current generation, 1.62 MB | 2,330 | 4,320 | 7,840 | 13,770 |
| current generation, 2 MB | 2,030 | 3,770 | 6,840 | 12,020 |
| two generations older, 1.62 MB | 700 | 1,300 | 2,350 | 4,130 |
| two generations older, 2 MB | 400 | 740 | 1,350 | 2,370 |
| three generations older, 1.62 MB | 480 | 890 | 1,620 | 2,840 |
| three generations older, 2 MB | 180 | 340 | 620 | 1,080 |

A three-second budget leaves a second for the work outside the loop and
for a closure arriving a little after the third second:

| host generation and closure | step cap admitted in 3 seconds,<br>1 capability | 2 | 4 | 8 |
|---|---:|---:|---:|---:|
| current generation, 1.62 MB | 1,340 | 2,480 | 4,490 | 7,900 |
| current generation, 2 MB | 1,040 | 1,930 | 3,490 | 6,140 |
| two generations older, 1.62 MB | 110 | 210 | 380 | 670 |
| two generations older, 2 MB | none | none | none | none |
| three generations older, 1.62 MB | none | none | none | none |
| three generations older, 2 MB | none | none | none | none |

Both tables read the worst case for the voter twice over: the node
applies the whole closure, nothing having passed through its mempool, and
the closure is the costliest the caps admit. The transfers alone take
most of the window on the older hosts, which leaves them little room for
scripts at any capability count. On every host, for the same time the
cap can sit two to three times higher on a four-core voter, which is what
the change buys.

## Why an option and not part of the fix

Whether the change is needed depends on the target and on the hosts. Two
targets are on the table: ten times mainnet's bytes with the proportional
step cap, 1.62 MB and 360 Gsteps, and the testnet's proposal, 2 MB and
600 Gsteps. Read against the four-second projection, the first is within
the loop's reach of every host generation at one capability, and the
second asks the two older generations for two and four capabilities. Read
against the three-second projection, the current generation takes both
targets at one capability, the generation two steps older takes the first
only with four capabilities and the second not at all, and the oldest
takes neither. So the change either lets older hosts stay voters for a
given target or is not needed where the hosts are current, and which of
the two holds is what the measurements on the testnet and the cluster
have to say.

The loop fix goes first on its own, and this commit waits here, measured
and tested: the `LeiosVoting` unit tests and the ThreadNet Leios
properties pass, the latter at the suite's usual duration once the
pre-pass took a fixed number of threads instead of one per transaction.

## What stays sequential, and the next lever

The per-transaction floor is the ledger's rule without scripts: 115
microseconds on the laptop for a script transaction, 80 for a value
transfer, of which about 22 is one signature check and about 45 the
bookkeeping the reapply path also pays.

Signatures could be evaluated concurrently too, but the ledger labels them
only as static checks, together with every other static check, so skipping
them alone needs either a new label in the ledger or a consensus-only
static pass per transaction. On mainnet-like shapes of one to three keys
that is worth a tenth to a sixth of the apply time; on many-witness shapes
over half.

The remainder, the rule's bookkeeping and static checks, does not
parallelise without the ledger applying a batch.
