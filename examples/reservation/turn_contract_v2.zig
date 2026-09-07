//! Test-only worker whose turn state has a tighter attempts bound. Operation
//! contracts, versions, Ruby code and bootstrap are unchanged.
pub const operations = @import("contract.zig").operations;
pub const turn_contract = @import("contract.zig").turn_contract_v2;
