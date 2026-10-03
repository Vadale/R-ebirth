# Lifecycle deadline diagnostics

Two focused cases / six expectations passed on the existing D040 installed package;
no skip, test warning or failure. The original synthetic deferred-close case keeps
500 × 2 ms fixture steps, 90 s setup, 30 s lifecycle and 10 s drain bounds. A forced
zero-deadline guard demonstrates that diagnostics leave an already queued observer
pending; subsequent explicit draining settles it exactly once. No native rebuild.

The diagnostic stores parent/observer references only in these opt-in cases;
original dropped-reference ownership cases retain their previous scope. It records
native counters, promise states, pump timing and queue metadata without collecting,
cancelling or pumping after the deadline. This is diagnostic coverage, not a fix or
reproduction of the remote failure. A passing remote retry cannot establish its cause.
The retained testthat/R patch-version startup warning is not a test failure.
