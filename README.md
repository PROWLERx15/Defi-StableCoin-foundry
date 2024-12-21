(Realtive Stability) Anchored or Pegged -> $1.00
    -> Chanlink Price Feed
    -> Set a function to exchange ETH & BTC -> $$$
Stability Mechanism (Miniting): Algorithmic (Decentralized)
    -> People can only mint the stablecoin with enough collateral (coded)
Collateral: Exogenous (Crypto)
    -> wETH
    -> wBTC


-> What are our invariants/properties?
Invariant -> Property of the system that must always hold true

Fuzz Testing -> Throwing random data at our system in an attempt to break it

Stateless Fuzzing -> Where the state of the previous run is discarded fro every new run
Stateful Fuzzing -> Fuzzing where the final state of your previous run is the starting state of your next run

In Foundry -> Fuzz Tests = Random data to a function
Invariant Tests -> Random Data & Random Function calls to many functions

In foundry -> Fuzzing = Stateless Fuzzing
           -> Invariant = Stateful Fuzzing 