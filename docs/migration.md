# Storage Migration Strategy

Soroban persistent storage serialises `#[contracttype]` structs to XDR at compile time. Any change to a struct's field layout — adding, removing, or reordering fields — will cause existing ledger entries to fail deserialisation. `get_bounty` and `get_contributor` will panic rather than return stale data.

This document describes the available migration strategies and the recommended approach for MergeMint.

---

## Why schema changes break storage

The `#[contracttype]` macro generates XDR encoding derived from the field declaration order. Existing ledger entries encoded against `BountyV1` cannot be decoded with `BountyV2` if their XDR layouts differ. There is no automatic schema evolution in Soroban.

---

## Option 1 — Versioned structs (recommended)

Introduce a new struct for each breaking schema version and store an enum that wraps all versions under a single `DataKey`.

```rust
#[contracttype]
pub struct BountyV1 {
    pub creator: Address,
    pub reward_amount: i128,
    // ... original fields
}

#[contracttype]
pub struct BountyV2 {
    pub creator: Address,
    pub reward_amount: i128,
    pub tags: Vec<Symbol>,   // new field
    // ... other fields
}

#[contracttype]
pub enum BountyVersioned {
    V1(BountyV1),
    V2(BountyV2),
}
```

**On read** — deserialise the enum, match on the variant, and upgrade in place before returning:

```rust
pub fn get_bounty(env: &Env, id: BytesN<32>) -> Bounty {
    let versioned: BountyVersioned = env.storage().persistent()
        .get(&DataKey::Bounty(id.clone()))
        .unwrap_or_else(|| panic!("bounty not found"));

    match versioned {
        BountyVersioned::V1(v1) => migrate_v1_to_v2(v1),
        BountyVersioned::V2(v2) => v2,
    }
}
```

**Trade-offs:**
- No downtime required; migration is lazy and happens on first access.
- Ledger entries are never invalidated — old entries coexist with new ones.
- Read functions grow more complex with each version added.
- Old variants must be retained in the enum forever (or until a full migration is complete).

---

## Option 2 — Lazy migration on read (write-back pattern)

Similar to versioned structs but the migration is persisted back to storage on every read of an old entry, so old variants are gradually eliminated without a dedicated migration transaction.

```rust
pub fn get_bounty(env: &Env, id: BytesN<32>) -> BountyV2 {
    let versioned: BountyVersioned = env.storage().persistent()
        .get(&DataKey::Bounty(id.clone()))
        .expect("bounty not found");

    let current = match versioned {
        BountyVersioned::V1(v1) => {
            let upgraded = migrate_v1_to_v2(v1);
            // Write the upgraded entry back so future reads are free.
            env.storage().persistent()
                .set(&DataKey::Bounty(id), &BountyVersioned::V2(upgraded.clone()));
            upgraded
        }
        BountyVersioned::V2(v2) => v2,
    };
    current
}
```

**Trade-offs:**
- Eliminates old variants over time without a one-shot migration transaction.
- Every read of a stale entry pays a write fee.
- The contract must remain authorised to write during normal user operations.

---

## Option 3 — One-time admin migration function

Add an admin-only function that iterates over all bounties and rewrites them under the new schema in a single transaction.

```rust
pub fn migrate_bounties(env: &Env, admin: Address, ids: Vec<BytesN<32>>) {
    admin.require_auth();
    for id in ids.iter() {
        let old: BountyV1 = env.storage().persistent()
            .get(&DataKey::Bounty(id.clone()))
            .expect("bounty not found");
        let new = migrate_v1_to_v2(old);
        env.storage().persistent()
            .set(&DataKey::Bounty(id), &BountyVersioned::V2(new));
    }
}
```

**Trade-offs:**
- Clean cut-over; no version branching in read paths after migration completes.
- Migration must be executed before the new contract version goes live.
- Soroban instruction limits constrain how many entries can be migrated per invocation; large data sets require batched calls.
- Risk of partial migration if the transaction fails mid-way.

---

## Option 4 — Contract replacement

Deploy a new contract instance, copy state via an export/import mechanism, and redirect integrators to the new address.

**Trade-offs:**
- Guarantees a clean schema with no legacy code paths.
- All integrators must update to the new contract address.
- Requires coordinated deployment across the MergeMint API, TypeScript SDK, and any third-party tools.
- Most disruptive option; suitable only for major breaking changes that cannot be handled incrementally.

---

## Recommended approach for MergeMint

**Use versioned structs (Option 1) with lazy write-back (Option 2) for incremental changes.**

- Wrap `Bounty` and `Contributor` in `BountyVersioned` / `ContributorVersioned` enums.
- Perform in-place migration on read; write the upgraded struct back to storage immediately so future reads are free.
- Reserve the admin migration function (Option 3) for cases where a large number of entries must be upgraded before a deadline (e.g., TTL pressure).
- Reserve contract replacement (Option 4) for major architectural changes only.

### Versioning policy

| Change type | Strategy |
|---|---|
| Add optional field (`Option<T>`) | Versioned struct + lazy write-back |
| Add required field | Versioned struct + lazy write-back |
| Remove field | Versioned struct (keep old field in `V_n`, drop in `V_n+1`) |
| Reorder fields | Versioned struct |
| Change field type | Versioned struct |
| Rename `DataKey` variant | Admin migration or contract replacement |

### When to use `Option<T>` instead of a new struct version

If a new field is genuinely optional and `None` is a valid sentinel for "not set on old entries," adding `Option<T>` to the current struct avoids a version bump. Soroban XDR encodes `Option<T>` as a union with a presence flag, so `None` at the end of a struct is backward-compatible **only if** existing entries are regenerated with the `None` variant before the new code is deployed. In practice this means running an admin migration first; otherwise old entries still fail to deserialise.

---

## TTL considerations

Soroban persistent storage entries have a TTL. Migrated entries written back during a lazy read inherit the new TTL from the write call. Ensure that `extend_ttl` calls in `get_bounty` / `get_contributor` are applied to the migrated entry, not the stale one.

---

## Related documents

- [Architecture overview](architecture.md)
- [Event schema](event-schema.md)
- [CHANGELOG](../CHANGELOG.md)
