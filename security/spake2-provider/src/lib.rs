#![deny(unsafe_op_in_unsafe_fn)]

use hmac::{Hmac, KeyInit, Mac};
use pakery_core::crypto::CpaceGroup;
use pakery_crypto::{P256Group, Spake2P256};
use pakery_spake2::{PartyA, PartyAState, PartyB, PartyBState, Spake2Error, Spake2Output};
use rand::Rng;
use sha2::{Digest, Sha256};

const P256_ORDER_MINUS_ONE: [u8; 32] = [
    0xFF, 0xFF, 0xFF, 0xFF, 0x00, 0x00, 0x00, 0x00, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF,
    0xBC, 0xE6, 0xFA, 0xAD, 0xA7, 0x17, 0x9E, 0x84, 0xF3, 0xB9, 0xCA, 0xC2, 0xFC, 0x63, 0x25, 0x50,
];
const PIN_DOMAIN: &[u8] = b"HearPort-SPAKE2-v1";

enum SessionState {
    PartyA(PartyAState<Spake2P256>),
    PartyB(PartyBState<Spake2P256>),
}

#[repr(C)]
pub struct hearport_spake2_session {
    state: Option<SessionState>,
}

#[repr(C)]
pub struct hearport_spake2_output {
    output: Spake2Output,
}

fn valid_slice<'a>(ptr: *const u8, len: usize) -> Option<&'a [u8]> {
    if len == 0 {
        return Some(&[]);
    }
    if ptr.is_null() {
        return None;
    }
    // SAFETY: The caller owns the FFI contract. The null check above rejects
    // the only invalid pointer representation for a non-empty slice.
    Some(unsafe { std::slice::from_raw_parts(ptr, len) })
}

fn valid_mut_slice<'a>(ptr: *mut u8, len: usize) -> Option<&'a mut [u8]> {
    if len == 0 {
        return Some(&mut []);
    }
    if ptr.is_null() {
        return None;
    }
    // SAFETY: The caller owns the FFI contract and supplied writable storage.
    Some(unsafe { std::slice::from_raw_parts_mut(ptr, len) })
}

fn map_error(error: Spake2Error) -> i32 {
    match error {
        Spake2Error::InvalidPoint | Spake2Error::IdentityPoint => HEARPORT_SPAKE2_INVALID_POINT,
        Spake2Error::ConfirmationFailed => HEARPORT_SPAKE2_CONFIRMATION_FAILED,
        Spake2Error::InternalError(_) => HEARPORT_SPAKE2_INTERNAL_ERROR,
    }
}

const HEARPORT_SPAKE2_OK: i32 = 0;
const HEARPORT_SPAKE2_INVALID_ARGUMENT: i32 = 1;
const HEARPORT_SPAKE2_INVALID_POINT: i32 = 2;
const HEARPORT_SPAKE2_CONFIRMATION_FAILED: i32 = 3;
const HEARPORT_SPAKE2_INTERNAL_ERROR: i32 = 4;

fn scalar_from_bytes(bytes: &[u8]) -> Option<<P256Group as CpaceGroup>::Scalar> {
    if bytes.len() != 32 {
        return None;
    }
    let mut wide = [0u8; 64];
    wide[32..].copy_from_slice(bytes);
    P256Group::scalar_from_wide_bytes(&wide).ok()
}

fn reduce_pin_digest(mut digest: [u8; 32]) -> [u8; 32] {
    if digest >= P256_ORDER_MINUS_ONE {
        let mut borrow = 0u16;
        for index in (0..32).rev() {
            let minuend = digest[index] as u16;
            let subtrahend = P256_ORDER_MINUS_ONE[index] as u16 + borrow;
            digest[index] = minuend.wrapping_sub(subtrahend) as u8;
            borrow = u16::from(minuend < subtrahend);
        }
    }
    let mut carry = 1u16;
    for index in (0..32).rev() {
        let value = digest[index] as u16 + carry;
        digest[index] = value as u8;
        carry = value >> 8;
    }
    digest
}

#[no_mangle]
pub extern "C" fn hearport_spake2_sha256(
    input: *const u8,
    input_len: usize,
    output: *mut u8,
) -> i32 {
    let Some(input) = valid_slice(input, input_len) else {
        return HEARPORT_SPAKE2_INVALID_ARGUMENT;
    };
    let Some(output) = valid_mut_slice(output, 32) else {
        return HEARPORT_SPAKE2_INVALID_ARGUMENT;
    };
    output.copy_from_slice(&Sha256::digest(input));
    HEARPORT_SPAKE2_OK
}

#[no_mangle]
pub extern "C" fn hearport_spake2_hmac_sha256(
    key: *const u8,
    key_len: usize,
    message: *const u8,
    message_len: usize,
    output: *mut u8,
) -> i32 {
    let Some(key) = valid_slice(key, key_len) else {
        return HEARPORT_SPAKE2_INVALID_ARGUMENT;
    };
    let Some(message) = valid_slice(message, message_len) else {
        return HEARPORT_SPAKE2_INVALID_ARGUMENT;
    };
    let Some(output) = valid_mut_slice(output, 32) else {
        return HEARPORT_SPAKE2_INVALID_ARGUMENT;
    };
    let Ok(mut mac) = Hmac::<Sha256>::new_from_slice(key) else {
        return HEARPORT_SPAKE2_INVALID_ARGUMENT;
    };
    mac.update(message);
    output.copy_from_slice(&mac.finalize().into_bytes());
    HEARPORT_SPAKE2_OK
}

#[no_mangle]
pub extern "C" fn hearport_spake2_random(output: *mut u8, output_len: usize) -> i32 {
    let Some(output) = valid_mut_slice(output, output_len) else {
        return HEARPORT_SPAKE2_INVALID_ARGUMENT;
    };
    rand::rng().fill_bytes(output);
    HEARPORT_SPAKE2_OK
}

#[no_mangle]
pub extern "C" fn hearport_spake2_pin_to_scalar(
    pin: *const u8,
    pin_len: usize,
    output: *mut u8,
) -> i32 {
    let Some(pin) = valid_slice(pin, pin_len) else {
        return HEARPORT_SPAKE2_INVALID_ARGUMENT;
    };
    if pin.len() != 6 || !pin.iter().all(|byte| byte.is_ascii_digit()) {
        return HEARPORT_SPAKE2_INVALID_ARGUMENT;
    }
    let Some(output) = valid_mut_slice(output, 32) else {
        return HEARPORT_SPAKE2_INVALID_ARGUMENT;
    };
    let mut hasher = Sha256::new();
    hasher.update(PIN_DOMAIN);
    hasher.update([0]);
    hasher.update(pin);
    let scalar = reduce_pin_digest(hasher.finalize().into());
    output.copy_from_slice(&scalar);
    HEARPORT_SPAKE2_OK
}

#[no_mangle]
pub extern "C" fn hearport_spake2_begin(
    role: u8,
    scalar: *const u8,
    identity_a: *const u8,
    identity_a_len: usize,
    identity_b: *const u8,
    identity_b_len: usize,
    public_point: *mut u8,
    session_out: *mut *mut hearport_spake2_session,
) -> i32 {
    let Some(scalar_bytes) = valid_slice(scalar, 32) else {
        return HEARPORT_SPAKE2_INVALID_ARGUMENT;
    };
    let Some(identity_a) = valid_slice(identity_a, identity_a_len) else {
        return HEARPORT_SPAKE2_INVALID_ARGUMENT;
    };
    let Some(identity_b) = valid_slice(identity_b, identity_b_len) else {
        return HEARPORT_SPAKE2_INVALID_ARGUMENT;
    };
    let Some(public_point) = valid_mut_slice(public_point, 65) else {
        return HEARPORT_SPAKE2_INVALID_ARGUMENT;
    };
    if session_out.is_null() {
        return HEARPORT_SPAKE2_INVALID_ARGUMENT;
    }
    let Some(scalar) = scalar_from_bytes(scalar_bytes) else {
        return HEARPORT_SPAKE2_INVALID_ARGUMENT;
    };
    let mut rng = rand::rng();
    let state = match role {
        1 => {
            let Ok((message, state)) =
                PartyA::<Spake2P256>::start(&scalar, identity_a, identity_b, &[], &mut rng)
            else {
                return HEARPORT_SPAKE2_INTERNAL_ERROR;
            };
            if message.len() != 65 {
                return HEARPORT_SPAKE2_INTERNAL_ERROR;
            }
            public_point.copy_from_slice(&message);
            SessionState::PartyA(state)
        }
        2 => {
            let Ok((message, state)) =
                PartyB::<Spake2P256>::start(&scalar, identity_a, identity_b, &[], &mut rng)
            else {
                return HEARPORT_SPAKE2_INTERNAL_ERROR;
            };
            if message.len() != 65 {
                return HEARPORT_SPAKE2_INTERNAL_ERROR;
            }
            public_point.copy_from_slice(&message);
            SessionState::PartyB(state)
        }
        _ => return HEARPORT_SPAKE2_INVALID_ARGUMENT,
    };
    let boxed = Box::new(hearport_spake2_session { state: Some(state) });
    // SAFETY: session_out was checked for null and points to caller-owned
    // storage for one opaque pointer.
    unsafe { *session_out = Box::into_raw(boxed) };
    HEARPORT_SPAKE2_OK
}

#[no_mangle]
pub extern "C" fn hearport_spake2_finish(
    session: *mut hearport_spake2_session,
    peer_point: *const u8,
    peer_point_len: usize,
    output_out: *mut *mut hearport_spake2_output,
    confirmation: *mut u8,
) -> i32 {
    if session.is_null() || output_out.is_null() {
        return HEARPORT_SPAKE2_INVALID_ARGUMENT;
    }
    let Some(peer_point) = valid_slice(peer_point, peer_point_len) else {
        return HEARPORT_SPAKE2_INVALID_ARGUMENT;
    };
    let Some(confirmation) = valid_mut_slice(confirmation, 32) else {
        return HEARPORT_SPAKE2_INVALID_ARGUMENT;
    };
    // SAFETY: session must be a pointer returned by hearport_spake2_begin and
    // this consuming function is the single owner of that allocation.
    let mut session = unsafe { Box::from_raw(session) };
    let Some(state) = session.state.take() else {
        return HEARPORT_SPAKE2_INVALID_ARGUMENT;
    };
    let output = match state {
        SessionState::PartyA(state) => state.finish(peer_point),
        SessionState::PartyB(state) => state.finish(peer_point),
    };
    let Ok(output) = output else {
        return map_error(output.err().expect("checked by is_err"));
    };
    if output.confirmation_mac.len() != 32 || output.session_key.as_bytes().len() != 16 {
        return HEARPORT_SPAKE2_INTERNAL_ERROR;
    }
    confirmation.copy_from_slice(&output.confirmation_mac);
    let boxed = Box::new(hearport_spake2_output { output });
    // SAFETY: output_out was checked for null and points to caller-owned
    // storage for one opaque pointer.
    unsafe { *output_out = Box::into_raw(boxed) };
    HEARPORT_SPAKE2_OK
}

#[no_mangle]
pub extern "C" fn hearport_spake2_verify_confirmation(
    output: *const hearport_spake2_output,
    confirmation: *const u8,
) -> i32 {
    if output.is_null() {
        return HEARPORT_SPAKE2_INVALID_ARGUMENT;
    }
    let Some(confirmation) = valid_slice(confirmation, 32) else {
        return HEARPORT_SPAKE2_INVALID_ARGUMENT;
    };
    // SAFETY: output is an opaque pointer returned by begin/finish and remains
    // alive for the duration of this call.
    let output = unsafe { &*output };
    match output.output.verify_peer_confirmation(confirmation) {
        Ok(()) => HEARPORT_SPAKE2_OK,
        Err(Spake2Error::ConfirmationFailed) => HEARPORT_SPAKE2_CONFIRMATION_FAILED,
        Err(error) => map_error(error),
    }
}

#[no_mangle]
pub extern "C" fn hearport_spake2_copy_session_key(
    output: *const hearport_spake2_output,
    session_key: *mut u8,
) -> i32 {
    if output.is_null() {
        return HEARPORT_SPAKE2_INVALID_ARGUMENT;
    }
    let Some(session_key) = valid_mut_slice(session_key, 16) else {
        return HEARPORT_SPAKE2_INVALID_ARGUMENT;
    };
    // SAFETY: output is an opaque pointer returned by begin/finish and remains
    // alive for the duration of this call.
    let output = unsafe { &*output };
    if output.output.session_key.as_bytes().len() != 16 {
        return HEARPORT_SPAKE2_INTERNAL_ERROR;
    }
    session_key.copy_from_slice(output.output.session_key.as_bytes());
    HEARPORT_SPAKE2_OK
}

#[no_mangle]
pub extern "C" fn hearport_spake2_session_free(session: *mut hearport_spake2_session) {
    if !session.is_null() {
        // SAFETY: only pointers returned by begin may be passed here.
        unsafe { drop(Box::from_raw(session)) };
    }
}

#[no_mangle]
pub extern "C" fn hearport_spake2_output_free(output: *mut hearport_spake2_output) {
    if !output.is_null() {
        // SAFETY: only pointers returned by finish may be passed here.
        unsafe { drop(Box::from_raw(output)) };
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use pakery_spake2::{PartyA, PartyB};

    fn hex(value: &str) -> Vec<u8> {
        (0..value.len())
            .step_by(2)
            .map(|index| u8::from_str_radix(&value[index..index + 2], 16).unwrap())
            .collect()
    }

    #[test]
    fn pin_scalar_matches_hearport_vector() {
        let mut output = [0u8; 32];
        assert_eq!(
            hearport_spake2_pin_to_scalar(b"000001".as_ptr(), 6, output.as_mut_ptr()),
            0
        );
        assert_eq!(
            output,
            hex("953b4ede8ce205547f1e941484ea9c4171029c3b305327f36ee8837a7ba70884").as_slice()
        );
    }

    #[test]
    fn rfc9382_p256_vector_derives_matching_key_and_confirmations() {
        let w = hex("2ee57912099d31560b3a44b1184b9b4866e904c49d12ac5042c97dca461b1a5f");
        let x = hex("43dd0fd7215bdcb482879fca3220c6a968e66d70b1356cac18bb26c84a78d729");
        let y = hex("dcb60106f276b02606d8ef0a328c02e4b629f84f89786af5befb0bc75b6e66be");
        let scalar_w = scalar_from_bytes(&w).unwrap();
        let scalar_x = scalar_from_bytes(&x).unwrap();
        let scalar_y = scalar_from_bytes(&y).unwrap();
        let (pa, state_a) = PartyA::<Spake2P256>::start_with_scalar(
            &scalar_w,
            &scalar_x,
            b"server",
            b"client",
            &[],
        )
        .unwrap();
        let (pb, state_b) = PartyB::<Spake2P256>::start_with_scalar(
            &scalar_w,
            &scalar_y,
            b"server",
            b"client",
            &[],
        )
        .unwrap();
        assert_eq!(hex("04a56fa807caaa53a4d28dbb9853b9815c61a411118a6fe516a8798434751470f9010153ac33d0d5f2047ffdb1a3e42c9b4e6be662766e1eeb4116988ede5f912c"), pa);
        assert_eq!(hex("0406557e482bd03097ad0cbaa5df82115460d951e3451962f1eaf4367a420676d09857ccbc522686c83d1852abfa8ed6e4a1155cf8f1543ceca528afb591a1e0b7"), pb);
        let output_a = state_a.finish(&pb).unwrap();
        let output_b = state_b.finish(&pa).unwrap();
        assert_eq!(
            output_a.session_key.as_bytes(),
            hex("0e0672dc86f8e45565d338b0540abe69")
        );
        assert_eq!(
            output_b.session_key.as_bytes(),
            output_a.session_key.as_bytes()
        );
        assert_eq!(
            output_a.confirmation_mac,
            hex("58ad4aa88e0b60d5061eb6b5dd93e80d9c4f00d127c65b3b35b1b5281fee38f0")
        );
        assert_eq!(
            output_b.confirmation_mac,
            hex("d3e2e547f1ae04f2dbdbf0fc4b79f8ecff2dff314b5d32fe9fcef2fb26dc459b")
        );
        output_a
            .verify_peer_confirmation(&output_b.confirmation_mac)
            .unwrap();
        output_b
            .verify_peer_confirmation(&output_a.confirmation_mac)
            .unwrap();
    }

    #[test]
    fn malformed_or_wrong_confirmation_fails_closed() {
        let mut output = [0u8; 32];
        let scalar = hex("2ee57912099d31560b3a44b1184b9b4866e904c49d12ac5042c97dca461b1a5f");
        let mut point_a = [0u8; 65];
        let mut session_a = std::ptr::null_mut();
        assert_eq!(
            hearport_spake2_begin(
                1,
                scalar.as_ptr(),
                std::ptr::null(),
                0,
                std::ptr::null(),
                0,
                point_a.as_mut_ptr(),
                &mut session_a
            ),
            HEARPORT_SPAKE2_OK
        );
        let mut point_b = [0u8; 65];
        let mut session_b = std::ptr::null_mut();
        assert_eq!(
            hearport_spake2_begin(
                2,
                scalar.as_ptr(),
                std::ptr::null(),
                0,
                std::ptr::null(),
                0,
                point_b.as_mut_ptr(),
                &mut session_b
            ),
            HEARPORT_SPAKE2_OK
        );
        let mut output_a = std::ptr::null_mut();
        assert_eq!(
            hearport_spake2_finish(
                session_a,
                point_b.as_ptr(),
                64,
                &mut output_a,
                output.as_mut_ptr()
            ),
            HEARPORT_SPAKE2_INVALID_POINT
        );
        hearport_spake2_session_free(session_b);
    }
}
