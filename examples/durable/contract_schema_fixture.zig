//! Test fixture: only the whole-turn schema changes, preserving every other
//! host/application input used by the durable retry fingerprint.
const original = @import("durable_original_contract");
pub const operations = original.operations;
pub const grants = original.grants;
pub const turn_contract = original.turn_contract_v2;
pub const max_bytes = original.max_bytes;
pub const max_receipt_bytes = original.max_receipt_bytes;
pub const max_snapshot_rows = original.max_snapshot_rows;
pub const bootstrap_contract = original.bootstrap_contract;
pub const Phase = original.Phase;
pub const Checkpoint = original.Checkpoint;
