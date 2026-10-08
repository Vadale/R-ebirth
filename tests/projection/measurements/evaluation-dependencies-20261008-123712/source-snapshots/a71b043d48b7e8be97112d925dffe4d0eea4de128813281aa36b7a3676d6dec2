// D-041: R-only admission/conversion and identity-correlated acknowledgement.
// The worker's owned LiveState never contains an R object or callback.
use rebirth_llm::{LiveCoefficient, LiveRequest, LiveState, LiveSteer, LiveTrace};

fn live_protocol(reason: &str) -> RebirthError {
    RebirthError::Internal {
        context: format!("live state protocol: {reason}"),
    }
}
fn live_data_frame(mut data: Robj, rows: usize) -> Result<Robj, RebirthError> {
    let rows = i32::try_from(rows).map_err(|_| live_protocol("row count overflow"))?;
    data.set_attrib("class", "data.frame")
        .map_err(|_| live_protocol("data frame class"))?;
    data.set_attrib(
        "row.names",
        if rows == 0 {
            Vec::<i32>::new()
        } else {
            vec![i32::MIN, -rows]
        },
    )
    .map_err(|_| live_protocol("data frame row names"))?;
    Ok(data)
}

fn live_state_payload(state: LiveState) -> Result<Robj, RebirthError> {
    let state_id = i32::try_from(state.state_id).map_err(|_| live_protocol("state id overflow"))?;
    let prompt_count = i32::try_from(state.prompt_token_count)
        .map_err(|_| live_protocol("prompt count overflow"))?;
    let step = live_data_frame(
        list!(
            state_id = state_id,
            prompt_id = 1i32,
            token_pos = state_id,
            token_id = from_engine_token(state.token_id),
            context_pos = from_engine_index(state.context_pos),
            source_pos = from_engine_index(state.source_pos),
            source = if state_id == 1 { "prompt" } else { "generated" },
            elapsed = state.elapsed,
            steering_revision = i32::try_from(state.steering_revision)
                .map_err(|_| live_protocol("steering revision overflow"))?,
            applied_after_state = i32::try_from(state.applied_after_state)
                .map_err(|_| live_protocol("applied state overflow"))?,
            effective_source_pos = from_engine_index(state.effective_source_pos)
        )
        .into(),
        1,
    )?;
    let k = state.logits.len();
    let logits = live_data_frame(
        list!(
            prompt_id = vec![1i32; k],
            rank = (1..=k as i32).collect::<Vec<_>>(),
            token_id = state
                .logits
                .iter()
                .map(|e| from_engine_token(e.token_id))
                .collect::<Vec<_>>(),
            token = state
                .logits
                .iter()
                .map(|e| e.token.as_str())
                .collect::<Vec<_>>(),
            logit = state
                .logits
                .iter()
                .map(|e| e.logit as f64)
                .collect::<Vec<_>>(),
            prob = state.logits.iter().map(|e| e.prob).collect::<Vec<_>>()
        )
        .into(),
        k,
    )?;
    let trace = match state.trace {
        LiveTrace::Memory(rows) => trace_payload(&rows, false),
        #[cfg(feature = "spill")]
        LiveTrace::Spilled(spill) => {
            let original = spill_payload(&spill.report)
                .as_list()
                .ok_or_else(|| live_protocol("spill payload is not a list"))?;
            let mut pairs: Vec<(String, Robj)> = original
                .iter()
                .map(|(name, value)| (name.to_string(), value))
                .collect();
            pairs.push(("spec_key".into(), spill.spec_key.clone().into()));
            pairs.push(("batch_bytes".into(), (spill.batch_bytes as f64).into()));
            pairs.push((
                "serialized_bytes".into(),
                (spill.serialized_bytes as f64).into(),
            ));
            List::from_pairs(pairs).into()
        }
    };
    let steering = live_data_frame(
        list!(
            intervention = state
                .steering
                .iter()
                .map(|r| from_engine_index(r.intervention))
                .collect::<Vec<_>>(),
            layer = state
                .steering
                .iter()
                .map(|r| from_engine_index(r.layer))
                .collect::<Vec<_>>(),
            coef = state.steering.iter().map(|r| r.coef).collect::<Vec<_>>()
        )
        .into(),
        state.steering.len(),
    )?;
    Ok(list!(
        step = step,
        logits = logits,
        trace = trace,
        prompt_token_count = prompt_count,
        steering = steering
    )
    .into())
}

#[extendr]
fn rebirth_async_state_ack(ptr: Robj, job_id: &str, state_id: i32, updates: Robj) -> Robj {
    resolve(catch_unwind(AssertUnwindSafe(|| {
        let handle = checked_handle(&ptr)?;
        ACTIVE_JOB.with(|slot| {
            let mut slot = slot.borrow_mut();
            let active = active_for(&mut slot, handle, job_id)?;
            let (native_id, pending_id, steer_count) = active
                .live_pending
                .ok_or_else(|| live_protocol("no delivered state awaiting acknowledgement"))?;
            if state_id < 1 || state_id as usize != pending_id {
                return Err(live_protocol("stale or wrong state acknowledgement"));
            }
            let command = parse_live_reply(&updates, steer_count)?;
            active
                .job
                .ack_state_with_reply(native_id, pending_id, command)?;
            active.live_pending = None;
            Ok::<_, RebirthError>(())
        })?;
        Ok(async_ok())
    })))
}

fn parse_live_reply(
    value: &Robj,
    steer_count: usize,
) -> Result<Vec<LiveCoefficient>, RebirthError> {
    let invalid = || async_argument("on_state_reply", "invalid coefficient reply");
    if value.is_null() {
        return Ok(Vec::new());
    }
    let list = value.as_list().ok_or_else(invalid)?;
    if list.len() != 2
        || list.names().map(|n| n.collect::<Vec<_>>()) != Some(vec!["intervention", "coef"])
    {
        return Err(invalid());
    }
    let indices = list.elt(0).map_err(|_| invalid())?;
    let coefficients = list.elt(1).map_err(|_| invalid())?;
    let ids = indices.as_integer_slice().ok_or_else(invalid)?;
    let coefs = coefficients.as_real_slice().ok_or_else(invalid)?;
    if ids.len() != coefs.len()
        || ids.len() > steer_count
        || ids
            .iter()
            .enumerate()
            .any(|(i, &id)| id < 1 || ids[..i].contains(&id))
        || coefs
            .iter()
            .any(|x| !x.is_finite() || x.abs() > f32::MAX as f64)
    {
        return Err(invalid());
    }
    let mut command = Vec::with_capacity(ids.len());
    for (&id, &coef) in ids.iter().zip(coefs) {
        command.push(LiveCoefficient {
            intervention: (id - 1) as u32,
            coef,
        });
    }
    Ok(command)
}

// Inspect borrowed R strings before building any owned live metadata. The
// caller includes these four descriptors in the shared ordinary request cap.
fn inspect_live_strings(value: &Robj, total: &mut usize) -> Result<usize, RebirthError> {
    if value.is_null() {
        return Ok(0);
    }
    let list = value
        .as_list()
        .ok_or_else(|| async_argument("on_state", "invalid live configuration"))?;
    for field in ["spill_dir", "trace_id", "model", "spec_key"] {
        let mut matches = list.iter().filter(|(name, _)| *name == field);
        let (_, text) = matches
            .next()
            .ok_or_else(|| async_argument("on_state", "missing live metadata"))?;
        if matches.next().is_some() || text.len() != 1 {
            return Err(async_argument("on_state", "invalid live metadata scalar"));
        }
        inspect_strings(&text, "on_state", total)?;
    }
    Ok(4)
}

fn parse_live_request(
    value: &Robj,
    metadata: &ModelMetadata,
    max_tokens: usize,
) -> Result<Option<LiveRequest>, RebirthError> {
    if value.is_null() {
        return Ok(None);
    }
    inspect_live_strings(value, &mut 0)?;
    let list = value
        .as_list()
        .ok_or_else(|| async_argument("on_state", "invalid live configuration"))?;
    let expected = [
        "layers",
        "components",
        "top",
        "budget_bytes",
        "r_fixed_bytes",
        "spill",
        "spill_dir",
        "trace_id",
        "model",
        "spec_key",
        "steering",
    ];
    let names: Vec<_> = list.iter().map(|(name, _)| name.to_string()).collect();
    if names.len() != expected.len()
        || expected
            .iter()
            .any(|name| names.iter().filter(|n| n.as_str() == *name).count() != 1)
    {
        return Err(async_argument(
            "on_state",
            "incomplete or duplicate live configuration fields",
        ));
    }
    let field = |name: &str| {
        list.iter()
            .find(|(key, _)| *key == name)
            .map(|(_, value)| value)
            .ok_or_else(|| async_argument("on_state", "missing live configuration field"))
    };
    let integer = |name: &str| -> Result<u64, RebirthError> {
        let value = field(name)?;
        let n = value
            .as_real()
            .ok_or_else(|| async_argument(name, "expected numeric scalar"))?;
        if value.len() != 1
            || !n.is_finite()
            || n < 0.0
            || n.fract() != 0.0
            || n >= 9007199254740992.0
        {
            return Err(async_argument(name, "expected exact nonnegative integer"));
        }
        Ok(n as u64)
    };
    let text = |name: &str| -> Result<String, RebirthError> {
        let value = field(name)?;
        if value.len() != 1 {
            return Err(async_argument(name, "expected one string"));
        }
        value
            .as_str()
            .filter(|s| !s.is_na())
            .map(str::to_owned)
            .ok_or_else(|| async_argument(name, "expected nonmissing string"))
    };
    let layer_value = field("layers")?;
    let layers = layer_value
        .as_integer_slice()
        .ok_or_else(|| async_argument("layers", "expected integer layer vector"))?
        .iter()
        .map(|&n| {
            if n < 1 {
                Err(async_argument("layers", "layers are 1-based"))
            } else {
                Ok((n - 1) as u32)
            }
        })
        .collect::<Result<Vec<_>, _>>()?;
    let component_value = field("components")?;
    let components = component_value
        .as_str_iter()
        .ok_or_else(|| async_argument("components", "expected component names"))?
        .map(|name| {
            Component::parse(name).ok_or_else(|| async_argument("components", "unknown component"))
        })
        .collect::<Result<Vec<_>, _>>()?;
    let spill_value = field("spill")?;
    if spill_value.len() != 1 {
        return Err(async_argument("spill", "expected logical scalar"));
    }
    let spill = spill_value
        .as_bool()
        .ok_or_else(|| async_argument("spill", "expected nonmissing logical"))?;
    let mut request = LiveRequest {
        layers,
        components,
        top: integer("top")? as usize,
        budget_bytes: integer("budget_bytes")?,
        r_fixed_bytes: integer("r_fixed_bytes")?,
        spill,
        spill_dir: text("spill_dir")?,
        trace_id: text("trace_id")?,
        model: text("model")?,
        spec_key: text("spec_key")?,
        steering: Vec::new(),
    };
    let steering_value = field("steering")?;
    let steering = steering_value
        .as_list()
        .ok_or_else(|| async_argument("on_state", "expected steering entries"))?;
    let values = steering
        .len()
        .checked_mul(metadata.hidden_size.max(0) as usize)
        .ok_or_else(|| async_argument("on_state", "steering shape overflow"))?;
    let values = u64::try_from(values)
        .map_err(|_| async_argument("on_state", "steering shape exceeds exact byte range"))?;
    request.preflight_with_steering_shape(metadata, max_tokens, steering.len(), values)?;
    // Validate every borrowed R vector before allocating any immutable direction copy.
    let entry = |value: &Robj| -> Result<(u32, u32, f64, Robj), RebirthError> {
        let invalid = || async_argument("on_state", "invalid original steering entry");
        let row = value.as_list().ok_or_else(invalid)?;
        let names: Vec<_> = row.iter().map(|(n, _)| n).collect();
        if names != ["intervention", "layer", "coef", "direction"] {
            return Err(invalid());
        }
        let get = |i| row.elt(i).map_err(|_| invalid());
        let index_value = get(0)?;
        let layer_value = get(1)?;
        let coef_value = get(2)?;
        let index = index_value.as_integer().ok_or_else(invalid)?;
        let layer = layer_value.as_integer().ok_or_else(invalid)?;
        let coef = coef_value.as_real().ok_or_else(invalid)?;
        let direction = get(3)?;
        let numbers = direction.as_real_slice().ok_or_else(invalid)?;
        if index_value.len() != 1
            || layer_value.len() != 1
            || coef_value.len() != 1
            || index < 1
            || layer < 1
            || layer > metadata.layers
            || !coef.is_finite()
            || numbers.len() != metadata.hidden_size as usize
            || numbers.iter().any(|x| !x.is_finite())
        {
            return Err(invalid());
        }
        Ok(((index - 1) as u32, (layer - 1) as u32, coef, direction))
    };
    let mut previous = None;
    for (_, value) in steering.iter() {
        let (index, _, _, _) = entry(&value)?;
        if previous.is_some_and(|p| index <= p) {
            return Err(async_argument("on_state", "steering indices must increase"));
        }
        previous = Some(index);
    }
    request.steering = Vec::with_capacity(steering.len());
    for (_, value) in steering.iter() {
        let (intervention, layer, coef, direction) = entry(&value)?;
        request.steering.push(LiveSteer {
            intervention,
            layer,
            coef,
            direction: std::sync::Arc::<[f64]>::from(
                direction
                    .as_real_slice()
                    .ok_or_else(|| live_protocol("validated direction disappeared"))?,
            ),
        });
    }
    request.preflight(metadata, max_tokens)?;
    Ok(Some(request))
}

#[extendr]
fn rebirth_live_preflight(ptr: Robj, config: Robj, max_tokens: i32) -> Robj {
    with_model(&ptr, |model| {
        if max_tokens < 1 {
            return Err(async_argument("max_tokens", "expected positive count"));
        }
        let metadata = model.metadata();
        let request = parse_live_request(&config, &metadata, max_tokens as usize)?
            .ok_or_else(|| async_argument("on_state", "missing live configuration"))?;
        let estimate = request.preflight(&metadata, max_tokens as usize)?;
        Ok(list!(
            ok = true,
            materialized_bytes = estimate.materialized_bytes as f64,
            logits_bytes = estimate.logits_bytes as f64,
            native_capture_bytes = estimate.native_capture_bytes as f64,
            transient_bytes = estimate.transient_bytes as f64,
            spill_bytes = estimate.spill_bytes as f64,
            batch_bytes = estimate.batch_bytes as f64,
            spilled = estimate.spilled,
            n_values = estimate.n_values as f64,
            n_vectors = estimate.n_vectors as f64,
            hidden_size = estimate.hidden_size as f64,
            max_piece_bytes = estimate.max_piece_bytes as f64,
            native_fixed_bytes = estimate.native_fixed_bytes as f64,
            ffi_intern_bytes = estimate.ffi_intern_bytes as f64,
            schema_frame_bytes = estimate.schema_frame_bytes as f64,
            record_frame_bytes = estimate.record_frame_bytes as f64,
            arrow_metadata_workspace_bytes = estimate.arrow_metadata_workspace_bytes as f64,
            arrow_body_bytes = estimate.arrow_body_bytes as f64,
            r_payload_bytes = estimate.r_payload_bytes as f64,
            r_assembly_bytes = estimate.r_assembly_bytes as f64,
            native_logits_bytes = estimate.native_logits_bytes as f64,
            capture_writer_bytes = estimate.capture_writer_bytes as f64,
            wp10_peak_bytes = estimate.wp10_peak_bytes as f64,
            steering_bytes = estimate.steering_bytes as f64,
            steering_descriptor_bytes = estimate.steering_descriptor_bytes as f64,
            steering_probe_bytes = estimate.steering_probe_bytes as f64,
            steering_probe_fixed_bytes = estimate.steering_probe_fixed_bytes as f64
        )
        .into())
    })
}
