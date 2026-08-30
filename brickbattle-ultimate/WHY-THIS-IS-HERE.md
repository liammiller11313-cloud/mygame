# Why this directory exists (temporary)

Brickbattle Ultimate lives in its own repository — `brickbattle-ultimate` — per
`docs/DECISIONS.md` D1. That repository does not exist on GitHub yet: creating
one requires a permission the GitHub App here does not have, so it is a manual
step (github.com/new, private, nothing pre-added).

This directory is a **mirror**, nothing more. The session that built it runs in
an ephemeral container that is reclaimed after a period of inactivity, and work
that exists only on that container's disk is work that can evaporate. So it is
parked on this branch — which is itself a brickbattle branch, not Fading
Light's default — until it has a real home.

**Delete this whole directory the moment the real repository exists** and the
history has been pushed there. Two copies of a codebase in two places is exactly
how they diverge.

Nothing in here is part of Fading Light. Nothing in Fading Light reads it.
