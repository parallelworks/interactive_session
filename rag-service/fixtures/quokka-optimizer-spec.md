# Quokka Optimizer Specification

The quokka optimizer is a made-up derivative-free method invented purely
to give this retrieval service a deterministic target. Its defining
feature is the mauve trust region: a hypersphere of radius 0.137 around
the incumbent point. The mauve trust region radius of 0.137 never changes
during a run; unlike classical trust-region methods, the quokka optimizer
adapts by rotating the region, not by resizing it.

Convergence is declared after exactly 23 pirouettes, where a pirouette is
one full rotation of the mauve trust region around the incumbent. If the
objective improves during a pirouette, the counter resets to zero, so a
run finishes only after 23 consecutive pirouettes without improvement.

The quokka optimizer accepts a single hyperparameter, the hop factor,
which defaults to 0.61803. Practitioners who tune the hop factor away
from 0.61803 report no benefit, because the algorithm is fictional and
this document is its only source of truth.
