//! Model-free transfer checks. No context, probe, or projection can be armed.
use super::*;

#[test]
fn projection_transfer_residual_shapes_and_values() {
    let mut good = InterventionSpec::new(2, 3);
    good.add_steer(1, &[1., -1.]);
    good.add_ablation(0, &[1], 0.25);
    assert!(good.projection_validate_residual(2, 3, 1, 1).is_ok());
    let empty = InterventionSpec::new(2, 3);
    assert!(empty.projection_validate_residual(2, 3, 0, 0).is_ok());
    let mut zero = InterventionSpec::new(2, 3);
    zero.add_steer(1, &[0., 0.]);
    assert!(zero.projection_validate_residual(2, 3, 1, 0).is_ok());
    assert!(good.projection_validate_residual(3, 3, 1, 1).is_err());
    assert!(good.projection_validate_residual(2, 4, 1, 1).is_err());
    assert!(good.projection_validate_residual(2, 3, 0, 1).is_err());
    assert!(good.projection_validate_residual(2, 3, 1, 0).is_err());
    assert!(empty.projection_validate_residual(2, 3, 1, 0).is_err());
    assert!(empty.projection_validate_residual(2, 3, 0, 1).is_err());
    for value in [f32::NAN, f32::INFINITY, f32::NEG_INFINITY] {
        good.steer.as_mut().unwrap()[2] = value;
        assert!(good.projection_validate_residual(2, 3, 1, 1).is_err());
    }
    good.steer.as_mut().unwrap()[2] = 1.;
    good.ablate_mask.as_mut().unwrap()[1] = 0.5;
    assert!(good.projection_validate_residual(2, 3, 1, 1).is_err());
    good.ablate_mask.as_mut().unwrap()[1] = 0.;
    good.ablate_add.as_mut().unwrap()[1] = f32::NAN;
    assert!(good.projection_validate_residual(2, 3, 1, 1).is_err());
    good.ablate_add.as_mut().unwrap()[1] = 0.25;
    good.steer_il_range = Some((0, 1));
    assert!(good.projection_validate_residual(2, 3, 1, 1).is_err());
    good.steer_il_range = Some((2, 2));
    assert!(good.projection_validate_residual(2, 3, 1, 1).is_err());
    good.steer_il_range = Some((1, 1));
    good.ablate_il_range = Some((1, 2));
    assert!(good.projection_validate_residual(2, 3, 1, 1).is_err());
    println!("F6E_PROJECTION_TRANSFER_TEST {{\"test\":\"projection_transfer_residual_shapes_and_values\",\"status\":\"passed\",\"expected_cases\":17,\"executed_cases\":17,\"expected_rejections\":14,\"rejected_cases\":14}}");
}

#[test]
fn projection_transfer_residual_exact_capacities() {
    let mut spec = InterventionSpec::new(2, 3);
    spec.add_steer(1, &[1., -1.]);
    spec.add_ablation(0, &[1], 0.25);
    assert!(spec.projection_validate_residual(2, 3, 1, 1).is_ok());
    for which in 0..3 {
        let slot = match which {
            0 => &mut spec.steer,
            1 => &mut spec.ablate_mask,
            _ => &mut spec.ablate_add,
        };
        let old = slot.take().unwrap();
        let mut spare = Vec::with_capacity(7);
        spare.extend_from_slice(&old);
        *slot = Some(spare);
        assert!(spec.projection_validate_residual(2, 3, 1, 1).is_err());
        let slot = match which {
            0 => &mut spec.steer,
            1 => &mut spec.ablate_mask,
            _ => &mut spec.ablate_add,
        };
        *slot = Some(old);
    }
    spec.ablate_add = None;
    assert!(spec.projection_validate_residual(2, 3, 1, 1).is_err());
    println!("F6E_PROJECTION_TRANSFER_TEST {{\"test\":\"projection_transfer_residual_exact_capacities\",\"status\":\"passed\",\"expected_cases\":5,\"executed_cases\":5,\"expected_rejections\":4,\"rejected_cases\":4}}");
}
