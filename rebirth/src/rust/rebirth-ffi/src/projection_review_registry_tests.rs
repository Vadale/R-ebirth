//! Model-free registry closure. Rc release models the existing finalizer's
//! owner drop; this test does not initialize R or claim to execute R GC.
use super::*;

fn assert_charge_covers(registry: &Vec<Weak<u8>>, admitted_capacity: usize, bytes: u64) {
    use std::mem::size_of;
    assert!(registry.capacity() <= admitted_capacity + 1);
    assert_eq!(size_of::<Weak<u8>>(), size_of::<Weak<HandleState>>());
    let actual = (size_of::<Vec<Weak<u8>>>()
        + (admitted_capacity + registry.capacity()) * size_of::<Weak<u8>>()) as u64;
    assert!(actual <= bytes);
}

#[test]
fn projection_registry_reuses_expired_slots_without_weakening_admission() {
    let source = Rc::new(1u8);
    let mut registry = Vec::with_capacity(1);
    registry.push(Rc::downgrade(&source));
    let mut cases = 0;
    let mut rejected = 0;

    for _ in 0..64 {
        let candidate = Rc::new(2u8);
        let capacity = registry.capacity();
        let bytes = projection_registry_charge(capacity).unwrap();
        projection_reserve_registration(&mut registry, &source, &candidate, capacity, bytes)
            .unwrap();
        assert_eq!(registry.len(), 2);
        assert_eq!(registry.capacity(), 2);
        assert_eq!(registry[0].as_ptr(), Rc::as_ptr(&source));
        assert_eq!(registry[1].as_ptr(), Rc::as_ptr(&candidate));
        assert_charge_covers(&registry, capacity, bytes);
        drop(candidate);
        assert_eq!(registry[1].strong_count(), 0);
        assert_eq!(registry[0].strong_count(), 1);
        cases += 1;
    }

    let mut simultaneous = Vec::with_capacity(8);
    for _ in 0..8 {
        let candidate = Rc::new(3u8);
        let capacity = registry.capacity();
        let bytes = projection_registry_charge(capacity).unwrap();
        projection_reserve_registration(&mut registry, &source, &candidate, capacity, bytes)
            .unwrap();
        simultaneous.push(candidate);
        assert_eq!(registry.len(), simultaneous.len() + 1);
        assert_eq!(registry.capacity(), simultaneous.len() + 1);
        assert_eq!(registry[0].as_ptr(), Rc::as_ptr(&source));
        for (entry, owner) in registry[1..].iter().zip(&simultaneous) {
            assert_eq!(entry.as_ptr(), Rc::as_ptr(owner));
            assert_eq!(entry.strong_count(), 1);
        }
        assert_charge_covers(&registry, capacity, bytes);
        cases += 1;
    }
    let peak_live_entries = registry.len();
    assert_eq!(peak_live_entries, 9);

    let absent = Rc::new(4u8);
    let candidate = Rc::new(5u8);
    for refusal in 0..5 {
        let capacity = registry.capacity();
        let bytes = projection_registry_charge(capacity).unwrap();
        let allocation = registry.as_ptr();
        let entries: Vec<_> = registry
            .iter()
            .map(|w| (w.as_ptr(), w.strong_count(), w.weak_count()))
            .collect();
        let result = match refusal {
            0 => projection_reserve_registration(
                &mut registry,
                &source,
                &candidate,
                capacity + 1,
                projection_registry_charge(capacity + 1).unwrap(),
            ),
            1 => projection_reserve_registration(
                &mut registry,
                &source,
                &candidate,
                capacity,
                bytes - 1,
            ),
            2 => projection_reserve_registration(
                &mut registry,
                &absent,
                &candidate,
                capacity,
                bytes,
            ),
            3 => projection_reserve_registration(
                &mut registry,
                &source,
                &source,
                capacity,
                bytes,
            ),
            _ => projection_reserve_registration(
                &mut registry,
                &source,
                &simultaneous[0],
                capacity,
                bytes,
            ),
        };
        assert!(matches!(result, Err(RebirthError::Intervention { .. })));
        assert_eq!(registry.as_ptr(), allocation);
        assert_eq!(registry.capacity(), capacity);
        assert_eq!(registry.len(), entries.len());
        for (entry, expected) in registry.iter().zip(&entries) {
            assert_eq!(
                (entry.as_ptr(), entry.strong_count(), entry.weak_count()),
                *expected
            );
        }
        assert_eq!(*source, 1);
        cases += 1;
        rejected += 1;
    }

    drop(simultaneous);
    let capacity = registry.capacity();
    let bytes = projection_registry_charge(capacity).unwrap();
    projection_reserve_registration(&mut registry, &source, &candidate, capacity, bytes)
        .unwrap();
    assert_eq!(registry.len(), 2);
    assert_eq!(registry.capacity(), 2);
    assert_eq!(registry[0].as_ptr(), Rc::as_ptr(&source));
    assert_eq!(registry[1].as_ptr(), Rc::as_ptr(&candidate));
    assert_charge_covers(&registry, capacity, bytes);
    drop(candidate);
    assert_eq!(registry[1].strong_count(), 0);
    assert_eq!(*source, 1);
    cases += 1;

    assert_eq!((cases, rejected), (78, 5));
    println!(
        "F6E_PROJECTION_REVIEW_TEST {{\"test\":\"projection_registry_reuses_expired_slots_without_weakening_admission\",\"status\":\"passed\",\"expected_cases\":78,\"executed_cases\":{cases},\"expected_rejections\":5,\"rejected_cases\":{rejected},\"expected_values\":0,\"compared_values\":0,\"max_abs_error\":0.0,\"model_loads\":0,\"inference_calls\":0,\"sequential_registrations\":64,\"simultaneous_registrations\":8,\"peak_live_entries\":{peak_live_entries},\"final_capacity\":2,\"actual_r_gc_executed\":false}}"
    );
}
