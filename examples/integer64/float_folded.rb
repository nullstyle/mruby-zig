# Constant folding must not hide a forbidden Float intermediate.
(1.25 + 2.75).to_i
