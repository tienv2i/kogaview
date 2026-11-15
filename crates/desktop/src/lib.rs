//! Qt adapter: exposes a read-only view of Core identity plus a temporary
//! bridge probe used to prove the CXX-Qt property/invokable path in M0.
//!
//! The real state bridge, command submission and event observation arrive in
//! M1. QML must never mutate domain state directly.
//!
//! CXX-Qt generates camelCase `connect_*Changed` helpers for QML properties,
//! so allow that naming convention crate-wide.

#![allow(non_snake_case)]

pub mod bridge;

pub use bridge::*;
