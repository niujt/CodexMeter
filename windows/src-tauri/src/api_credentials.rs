use crate::api::Provider;

pub fn target(provider: Provider) -> &'static str {
    match provider {
        Provider::Openai => "CodexHealth/OpenAI/organization-admin-key",
        Provider::Deepseek => "CodexHealth/DeepSeek/user-api-key",
    }
}

pub fn valid(key: &str) -> bool {
    key.starts_with("sk-")
        && (16..=2048).contains(&key.len())
        && key
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || b == b'-' || b == b'_')
}

pub fn extract(text: &str) -> Result<String, String> {
    if text.len() > 16_384 {
        return Err("密钥文件过大，请选择只含一个 API Key 的文本。".into());
    }
    let keys: Vec<_> = text
        .split_whitespace()
        .map(|s| {
            s.split_once('=')
                .map_or(s, |(_, value)| value)
                .trim_matches(['\'', '"'])
        })
        .filter(|s| valid(s))
        .collect();
    if keys.len() != 1 {
        return Err("请选择只含一个有效 API Key 的文本，或直接输入密钥。".into());
    }
    Ok(keys[0].to_owned())
}

#[cfg(windows)]
pub fn read(provider: Provider) -> Result<Option<String>, String> {
    use windows_sys::Win32::{
        Foundation::{GetLastError, ERROR_NOT_FOUND},
        Security::Credentials::*,
    };
    let name: Vec<u16> = target(provider).encode_utf16().chain(Some(0)).collect();
    let mut credential = std::ptr::null_mut();
    // CredRead allocates this buffer; CredFree is used exactly once after copying its blob.
    unsafe {
        if CredReadW(name.as_ptr(), CRED_TYPE_GENERIC, 0, &mut credential) == 0 {
            return if GetLastError() == ERROR_NOT_FOUND {
                Ok(None)
            } else {
                Err("无法读取 Windows 凭据管理器，请重试。".into())
            };
        }
        if credential.is_null() {
            return Err("凭据记录无法识别。".into());
        }
        let item = &*credential;
        let result = if item.CredentialBlobSize == 0
            || item.CredentialBlobSize > 2048
            || item.CredentialBlob.is_null()
        {
            Err("保存的密钥无法识别，请重新配置。".to_string())
        } else {
            let bytes =
                std::slice::from_raw_parts(item.CredentialBlob, item.CredentialBlobSize as usize);
            String::from_utf8(bytes.to_vec())
                .ok()
                .filter(|s| valid(s))
                .map(Some)
                .ok_or_else(|| "保存的密钥无法识别，请重新配置。".to_string())
        };
        CredFree(credential.cast());
        result
    }
}

#[cfg(windows)]
pub fn save(provider: Provider, key: &str) -> Result<(), String> {
    use windows_sys::Win32::Security::Credentials::*;
    if !valid(key) {
        return Err("API Key 格式无效。".into());
    }
    let mut name: Vec<u16> = target(provider).encode_utf16().chain(Some(0)).collect();
    let mut user: Vec<u16> = "Codex Health".encode_utf16().chain(Some(0)).collect();
    let mut blob = key.as_bytes().to_vec();
    let credential = CREDENTIALW {
        Type: CRED_TYPE_GENERIC,
        TargetName: name.as_mut_ptr(),
        UserName: user.as_mut_ptr(),
        CredentialBlob: blob.as_mut_ptr(),
        CredentialBlobSize: blob.len() as u32,
        Persist: CRED_PERSIST_LOCAL_MACHINE,
        ..unsafe { std::mem::zeroed() }
    };
    let saved = unsafe { CredWriteW(&credential, 0) } != 0;
    blob.fill(0);
    if saved {
        Ok(())
    } else {
        Err("无法保存到 Windows 凭据管理器，原有密钥保留。".into())
    }
}

#[cfg(not(windows))]
pub fn read(_provider: Provider) -> Result<Option<String>, String> {
    Ok(None)
}
#[cfg(not(windows))]
pub fn save(_provider: Provider, _key: &str) -> Result<(), String> {
    Err("API 密钥保存需要 Windows 凭据管理器。".into())
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn separates_provider_credentials_and_rejects_ambiguous_imports() {
        assert_ne!(target(Provider::Openai), target(Provider::Deepseek));
        let key = "sk-synthetic-test-00000000";
        assert_eq!(
            extract(&format!("DEEPSEEK_API_KEY=\"{key}\"\n")).unwrap(),
            key
        );
        assert!(extract(&format!("{key}\n{key}")).is_err());
        assert!(!valid("sk-bad\r\nheader:injected"));
        assert!(extract("invalid").is_err());
    }
}
