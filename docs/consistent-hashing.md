# Consistent Hashing: Gateway Ring and Redis Cluster

**Project:** Student ID, please — PAD Lab 5
**Scope:** Grade 7 — consistent hashing and cache sharding
**Implementation:** Gateway, Python, app/cache/ring.py

## 1. Introduction

Lab 5 distributes the Gateway cache across three Valkey nodes:
cache-1, cache-2, and cache-3. Sharding allows different keys to be
stored and served by different cache nodes.

The central problem is deciding which node owns a key. The mapping
must be deterministic: every Gateway instance with identical ring
membership and configuration must select the same node for a key.

This document explains modulo hashing, consistent hashing, our
Gateway implementation, measured results, node failure and recovery,
and the differences between our ring and Redis Cluster.

Our implementation is an application-managed sharding layer over
standalone Valkey nodes. Redis Cluster is a complete distributed
Redis architecture with slot ownership, cluster communication,
replication, failover, and client redirection.

## 2. The problem with modulo hashing

A simple sharding strategy assigns a key with:

    node_index = hash(key) % number_of_nodes

With three nodes, the divisor is 3. When a fourth node is added,
the divisor becomes 4. The result changes for most keys.

Existing entries remain on their old nodes, but requests now look
for them on different nodes. This produces cache misses and can
increase traffic to the underlying services.

For a uniformly distributed hash, approximately 1/N of keys retain
their previous owner when changing from N to N+1 nodes. Therefore,
adding a fourth node to three nodes moves approximately 75% of keys.

Removing a node has the same weakness: changing the divisor remaps
most keys, not only the keys on the removed node.

This is disruptive for a cache because many previously warm entries
become inaccessible through the new mapping at the same time.

## 3. Consistent hashing and virtual nodes

Consistent hashing places both cache nodes and keys in the same
circular hash space, called a ring.

Each physical cache node is represented by multiple positions on
the ring. These positions are called virtual nodes, or vnodes.
A key is hashed to a position in the same space and assigned to
the first vnode encountered while moving clockwise.

If the key's position is greater than the final ring position,
the search wraps around to the first vnode.

When a physical node is added, only the keys in the ranges whose
clockwise owner changes need a new owner. When a node is removed,
only keys previously assigned to that node move to another node.
The other key assignments remain unchanged.

Virtual nodes improve distribution. Instead of giving each physical
node one position, the ring gives it many positions spread around
the hash space. This reduces the chance that one physical node
receives a disproportionately large range of keys.

More vnodes generally produce smoother distribution, but also
increase the number of ring positions that must be stored and
considered during ring updates.

## 4. Our Gateway ring implementation

The implementation is in `app/cache/ring.py` in the Gateway
repository.

### 4.1 Hash function

Our ring uses MD5 to produce a deterministic hash. The implementation
takes the first eight bytes of the MD5 digest and interprets them
as an unsigned, big-endian integer. This creates a 64-bit position
in the ring's hash space.

The same hashing method is used for physical-node virtual positions
and cache keys. This is important because both must occupy the same
coordinate system.

MD5 is used here only as a deterministic distribution function.
It is not used for authentication, integrity, or other security
purposes. Cryptographic collision resistance is not a requirement
of this cache-partitioning design.

### 4.2 Virtual-node naming and ring construction

Each virtual position is calculated from a string containing the
physical node name and its virtual-node index:

    cache-1#0
    cache-1#1
    ...
    cache-1#159

The implementation creates 160 virtual positions for each physical
node. With three physical nodes, the ring contains 480 positions.

The positions are sorted. To find a key's owner, the implementation
uses binary search with bisect_right to locate the first ring
position strictly greater than the key's hash. If no greater
position exists, it wraps around to position zero.

### 4.3 Why these parameters?

| Parameter | Our value | Reason |
|---|---:|---|
| Hash algorithm | MD5 | Deterministic and available in Python's standard library; only distribution is required |
| Hash-space width | 64 bits | The first eight digest bytes provide compact integer positions |
| Virtual nodes per physical node | 160 | Provides many positions per node to improve distribution without an excessive ring |
| Initial physical nodes | 3 | Matches the three Valkey cache nodes deployed by the project |
| Initial ring positions | 480 | 3 physical nodes multiplied by 160 virtual nodes each |

The ring is built from the configured node membership. Gateway
instances must use the same node names, hash algorithm, and vnode
count to independently calculate identical key ownership.

The implementation keeps the ordered ring data available for
lookups and protects ring membership changes with synchronization.
This allows lookups to use a consistent view while nodes are
added or removed.

## 5. Measured comparison: consistent hashing vs modulo

The Gateway ring module includes a command-line experiment that
compares how many keys change owners when a fourth node is added.

The experiment uses 10,000 keys, three initial nodes, and 160 virtual
nodes per physical node. Both strategies use the same key hashing
method so the comparison focuses on the partitioning algorithms.

Command:

    .venv/bin/python -m app.cache.ring --keys 10000 --nodes 3 --add 1

Measured output:

    10000 keys, 3 -> 4 nodes, 160 vnodes per node
    moved with the ring : 25.0% (ideal 25.0%)
    moved with hash % N : 74.0%
    distribution (ring) over 3 nodes: cache-1: 35.7%, cache-2: 32.2%, cache-3: 32.2%
    distribution (hash % N) over 3 nodes: cache-1: 33.1%, cache-2: 34.5%, cache-3: 32.4%

The experiment was run twice and produced the same results.

### 5.1 Key movement

When a fourth node is added, consistent hashing moves 25.0% of
the keys. This matches the ideal expected movement of approximately
1/4: the new node takes ownership of the portion of the ring that
falls between its virtual positions and their preceding positions.

Modulo hashing moves 74.0% of keys in the same experiment. This is
close to the theoretical expectation of 75% when changing from
three nodes to four.

The difference matters because moving fewer keys preserves more
cache locality. With modulo hashing, most existing keys are looked
up on a different node after scaling. With consistent hashing,
most keys retain their previous owner.

### 5.2 Distribution

The distribution figures in the output describe ownership across
the original three nodes, before the fourth node is added.

The ring distribution is cache-1: 35.7%, cache-2: 32.2%, and
cache-3: 32.2%. The displayed values add up to 100.1% because
each percentage is rounded to one decimal place.

The modulo distribution is cache-1: 33.1%, cache-2: 34.5%, and
cache-3: 32.4%.

Both strategies distribute these 10,000 test keys reasonably
evenly in this run. The main measured advantage of consistent
hashing is therefore not a dramatic improvement in this particular
initial distribution; it is the reduction in key movement when
membership changes.

## 6. Gateway node failure and recovery

Our Gateway manages the availability of its standalone Valkey
nodes in the cache client layer. This is application-level node
ejection and recovery, not Redis Cluster failover.

### 6.1 Ejection

The cache client tracks consecutive errors for each node. The
default failure threshold is three consecutive errors, and the
default connection/operation timeout is 50 milliseconds.

When a node reaches the failure threshold, the Gateway marks it
unavailable and removes it from the active ring. New key lookups
are then routed using the remaining active nodes.

If a request cannot acquire the Gateway's per-node concurrency
semaphore before the timeout, it is counted as busy and does not
increment the node's failure count. This prevents local capacity
pressure from immediately ejecting a healthy node.

### 6.2 Fail-open behavior

The cache is an optimization, not the source of truth. A cache
operation that raises an error or times out is treated as a miss
for reads or a skipped write, rather than failing the Gateway
request. The client does not retry that operation on another node.

After a node reaches the failure threshold and is ejected, the
ring is rebuilt without it. Subsequent lookups then use the
remaining active membership. The application must not depend on
a cache read or write succeeding for the underlying operation
to be correct.

### 6.3 Recovery and re-addition

The Gateway periodically retries unavailable nodes. The default
retry interval is ten seconds.

When a previously unavailable node responds successfully to a
PING, the client flushes that node's Redis database with FLUSHDB
before adding it back to the ring. This avoids exposing stale
entries that may no longer match the current ownership mapping.

After re-addition, the node receives keys assigned to its virtual
positions by the ring. Entries are populated again through normal
cache writes and read-through behavior.

### 6.4 Important limitations

The Gateway does not copy or replicate keys from an ejected node
to other nodes. Entries that were stored only on that node are
effectively lost from the cache when it becomes unavailable.

The health and membership state are managed by each Gateway
process. Separate Gateway instances can temporarily have different
views of node availability if they observe failures or recovery at
different times. Consistent hashing guarantees matching ownership
only when instances use the same active membership and configuration.

This design is acceptable because the cache is disposable and
the underlying application data remains authoritative. It is not
a substitute for replicated storage or a distributed database.

## 7. How Redis Cluster distributes keys

Redis Cluster uses a different sharding model from our Gateway ring.
It does not use consistent hashing. Instead, it divides the keyspace
into a fixed number of 16,384 hash slots.

### 7.1 Hash slots and CRC16

Redis calculates a key's slot using:

    HASH_SLOT = CRC16(key) mod 16384

The CRC16 variant is CRC-16/XMODEM. Each key therefore maps to
one of the slot numbers from 0 to 16,383.

Every primary (master) node owns a subset of these slots. For
example, a three-primary cluster could assign one range to each
primary:

| Primary | Example slot range |
|---|---:|
| Node A | 0–5,500 |
| Node B | 5,501–11,000 |
| Node C | 11,001–16,383 |

The exact ranges depend on the cluster configuration. The important
point is that the slot space is fixed, while the assignment of slots
to primary nodes can change.

### 7.2 Hash tags and multi-key operations

Redis Cluster supports hash tags to place related keys in the same
slot. When a key contains a valid non-empty substring between the
first opening brace and the following closing brace, Redis hashes
that substring instead of the entire key.

For example:

    {user:42}:profile
    {user:42}:settings
    {user:42}:sessions

All three keys hash using `user:42`, so they belong to the same slot.

This is important because multi-key commands generally require
all involved keys to belong to the same slot. Otherwise Redis
returns a `CROSSSLOT` error.

Hash tags allow applications to design key names so that related
data can participate in supported multi-key operations.

### 7.3 Adding a node and resharding

Adding a primary to Redis Cluster does not automatically redistribute
the keyspace using a new hash divisor or a ring. The new primary is
added and selected hash slots are moved from existing primaries to it.

A slot represents the set of keys that hash to that slot. Moving
a slot therefore involves migrating its keys to the destination
node and updating the cluster's slot ownership configuration.

During migration, the source slot can be marked MIGRATING and the
destination slot IMPORTING. The source can return an ASK redirection
for a key that is not present locally and is expected at the
destination.

This mechanism allows resharding while the cluster is running.
After the migration and ownership update complete, clients use
the new slot-to-node mapping.

### 7.4 MOVED and ASK redirections

Redis Cluster nodes do not proxy a misrouted command to the correct
node. They return a redirection that the client must follow.

- `MOVED` means the slot is served by another node. The client
  retries the command at the returned endpoint and updates its
  slot-to-node map. It may refresh the complete slot map.
- `ASK` means a slot is currently being migrated and the key may
  already be at the destination. The client sends `ASKING` to the
  destination and retries that command once. It does not treat
  this temporary redirect as a permanent slot-map update.

Cluster-aware clients handle these responses automatically.
A client that does not understand them cannot correctly use
Redis Cluster as a cluster-aware client.

### 7.5 Cluster membership, gossip, and failure handling

Redis Cluster nodes communicate over a separate cluster bus.
They exchange heartbeat and gossip information to discover nodes,
propagate membership information, and detect failures.

Failure detection has two states:

- `PFAIL` means a node is possibly unavailable from the local
  node's point of view.
- `FAIL` means the failure has been confirmed through reports
  from a majority of masters within the required time window.

When a primary fails, an eligible replica can request votes from
the masters and promote itself if it wins the election. The promoted
replica takes over the failed primary's slots.

Redis Cluster replication is asynchronous. It improves availability,
but it does not guarantee that every acknowledged write has reached
a replica before the primary fails. A small window of acknowledged
writes can therefore be lost during failover.

This is substantially different from our Gateway implementation:
our cache client ejects a failed standalone node from its local ring
and does not promote a replica or transfer the failed node's keys.

## 8. Gateway ring vs Redis Cluster

| Aspect | Our Gateway consistent-hash ring | Redis Cluster |
|---|---|---|
| Key-to-node mapping | MD5 hash of the key; select the first clockwise virtual position | CRC16/XMODEM of the key modulo 16,384; look up the slot owner |
| Partitioning structure | Sorted ring with 160 virtual positions per physical node | Fixed set of 16,384 hash slots assigned to primary nodes |
| Example key mapping | A key hashes to a ring coordinate and is assigned to the next virtual position clockwise | A key hashes to a slot, and the cluster slot map identifies its primary |
| Adding a node | Add its virtual positions; only keys whose clockwise owner changes are remapped | Add a primary and explicitly reshard slots and their keys from existing primaries |
| Moving existing data | The ring changes ownership, but our implementation does not copy old cache entries | Redis migrates keys belonging to slots being moved |
| Node failure | After three consecutive errors by default, the node is ejected from the active ring | Nodes exchange failure information; a majority-confirmed primary failure can trigger replica election and promotion |
| Recovery | Gateway retries the node; after a successful PING it issues FLUSHDB and re-adds the node | Cluster membership and slot ownership are coordinated through cluster configuration and node communication |
| Replication | No replication or replica promotion in our cache layer | Primaries can have replicas; replication is asynchronous |
| Client complexity | Gateway computes the ring owner and directly contacts that cache node | A cluster-aware client maintains or refreshes the slot map and handles MOVED and ASK |
| Multi-key operations | This ring selects a node per key; it does not provide cross-node transactions or Redis Cluster hash-tag semantics | Multi-key commands generally require all keys to be in the same slot; hash tags can co-locate related keys |
| Coordination | Ring membership and health state are local to each Gateway process | Redis nodes coordinate membership, slot configuration, and failure information through the cluster bus |
| Operational model | Application-managed sharding over standalone Valkey nodes; cache entries can be repopulated | Redis Cluster is a distributed Redis deployment with explicit slot management, replication, failover, and cluster-aware clients |

### 8.1 Example: where a key is routed

The two systems make the routing decision in different ways:

| Step | Gateway ring | Redis Cluster |
|---|---|---|
| 1. Input | `applicant:42` | `applicant:42` |
| 2. Calculate | MD5-derived 64-bit key coordinate | CRC16-derived slot number |
| 3. Find owner | First clockwise virtual position | Primary assigned to that slot |
| 4. Send command | Gateway cache client contacts the selected Valkey node | Cluster-aware client contacts the primary, or follows a redirection |
| 5. Configuration change | Rebuild active ring membership; ownership may change for some keys | Move slots and keys; update slot ownership and client routing information |

The table illustrates the routing process rather than claiming
specific node assignments for this example key. Actual ownership
depends on the running ring and cluster configuration.

### 8.2 Operational trade-offs

Our Gateway ring is simpler because it solves a narrower problem:
distributing disposable cache entries across several standalone
Valkey instances. It avoids running a Redis Cluster control plane
and makes cache failure non-fatal to the underlying application.

The trade-off is that it does not preserve cache contents when
a node disappears, replicate data, coordinate health state across
Gateway instances, or migrate keys during membership changes.
After a node is ejected, its entries may need to be repopulated.

Redis Cluster provides significantly more infrastructure for
distributed operation: fixed slots, key migration, cluster-wide
membership information, failure detection, replica promotion,
and client redirection. It also introduces operational requirements
such as slot balancing, replica configuration, cluster-aware
clients, and same-slot constraints for multi-key commands.

Neither approach eliminates every failure mode. Redis Cluster's
asynchronous replication can lose recently acknowledged writes,
while our Gateway cache intentionally accepts lost cache entries
because the underlying application data remains authoritative.

## 9. Conclusion

Consistent hashing addresses the key-remapping problem of modulo
sharding. In our measured experiment, adding a fourth node moved
25.0% of keys with the ring, compared with 74.0% using modulo
hashing. The ring therefore preserves substantially more key
ownership when the cache membership grows.

Our implementation uses MD5-derived ring positions and 160 virtual
nodes per physical node. The three configured Valkey nodes produce
480 virtual positions. The Gateway removes failed nodes from the
active ring, fails open when the cache is unavailable, and flushes
a recovered node before adding it back.

Redis Cluster solves a broader distributed-systems problem using
16,384 CRC16 hash slots, explicit slot migration, redirections,
gossip, and replica failover. It is not an implementation of the
same consistent-hashing algorithm.

For this project, the Gateway ring is an appropriate lightweight
solution because cache availability must not determine application
availability and the underlying data can repopulate the cache.

## 10. Sources

1. Redis, **Redis Cluster specification** — hash slots, CRC16,
   hash tags, cluster bus, redirections, failure detection,
   replica promotion, and replication behavior:
   https://redis.io/docs/latest/operate/oss_and_stack/reference/cluster-spec/

2. Redis, **Scale with Redis Cluster** — slot-based sharding and
   adding or removing nodes through slot migration:
   https://redis.io/docs/latest/management/scaling/

3. Redis, **Redis server errors** — definitions of MOVED, ASK,
   and CROSSSLOT:
   https://redis.io/docs/latest/develop/reference/errors/all/redis/

4. Redis, **CLUSTER INFO command** — cluster slot health and
   failure-state information:
   https://redis.io/docs/latest/commands/cluster-info/

5. Project Gateway, **consistent-hash ring implementation**
   (commit 334239e):
   https://github.com/mihaelaaa-23/gateway/blob/334239e/app/cache/ring.py

6. Project Gateway, **cache client and node health handling**
   (commit 70c600f):
   https://github.com/mihaelaaa-23/gateway/blob/70c600f/app/cache/client.py
