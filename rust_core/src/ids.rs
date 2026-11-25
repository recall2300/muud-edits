//! 엔티티 식별자.
//!
//! 편집기는 id를 문자열로 다루되, 서로 다른 종류의 id를 섞어 쓰는 실수를
//! 컴파일 단계에서 막기 위해 종류별 뉴타입을 둔다. JSON에서는 그냥 문자열이다.
//! `Project`가 단조 증가 카운터([`IdSeq`])를 들고 있어서,
//! 같은 프로젝트에서 만든 id는 저장/불러오기를 거쳐도 다시 겹치지 않는다.

use std::fmt;

use serde::{Deserialize, Serialize};

macro_rules! id_type {
    ($name:ident, $prefix:literal, $doc:literal) => {
        #[doc = $doc]
        #[derive(Clone, Debug, PartialEq, Eq, Hash, PartialOrd, Ord, Serialize, Deserialize)]
        #[serde(transparent)]
        pub struct $name(String);

        impl $name {
            /// 이 종류의 id 접두사.
            pub const PREFIX: &'static str = $prefix;

            pub fn new(raw: impl Into<String>) -> Self {
                Self(raw.into())
            }

            pub fn as_str(&self) -> &str {
                &self.0
            }

            pub fn into_string(self) -> String {
                self.0
            }
        }

        impl fmt::Display for $name {
            fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
                f.write_str(&self.0)
            }
        }

        impl From<&str> for $name {
            fn from(value: &str) -> Self {
                Self(value.to_owned())
            }
        }

        impl From<String> for $name {
            fn from(value: String) -> Self {
                Self(value)
            }
        }
    };
}

id_type!(TrackId, "trk", "트랙 식별자 (예: `trk-0003`).");
id_type!(ClipId, "clp", "클립 식별자 (예: `clp-0012`).");
id_type!(SubtitleId, "sub", "자막 아이템 식별자 (예: `sub-0007`).");

/// 프로젝트 단위 id 발급기.
///
/// 되돌리기를 해도 카운터는 줄이지 않는다. id 재사용으로 인한 충돌보다
/// id가 조금 비는 편이 안전하기 때문이다.
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct IdSeq {
    #[serde(default)]
    next: u64,
}

impl IdSeq {
    pub fn new(start: u64) -> Self {
        Self { next: start }
    }

    /// 접두사를 붙인 새 id 문자열을 발급한다.
    pub fn mint(&mut self, prefix: &str) -> String {
        self.next += 1;
        format!("{prefix}-{:04}", self.next)
    }

    /// 다음에 발급될 번호(디버깅/테스트용).
    pub fn peek(&self) -> u64 {
        self.next
    }

    pub fn mint_track(&mut self) -> TrackId {
        TrackId(self.mint(TrackId::PREFIX))
    }

    pub fn mint_clip(&mut self) -> ClipId {
        ClipId(self.mint(ClipId::PREFIX))
    }

    pub fn mint_subtitle(&mut self) -> SubtitleId {
        SubtitleId(self.mint(SubtitleId::PREFIX))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn mint_is_monotonic_and_prefixed() {
        let mut seq = IdSeq::default();
        assert_eq!(seq.mint_clip().as_str(), "clp-0001");
        assert_eq!(seq.mint_track().as_str(), "trk-0002");
        assert_eq!(seq.mint_clip().as_str(), "clp-0003");
        assert_eq!(seq.peek(), 3);
    }

    #[test]
    fn ids_serialize_as_plain_strings() {
        let id = ClipId::new("clp-0009");
        let json = serde_json::to_string(&id).expect("serialize");
        assert_eq!(json, "\"clp-0009\"");
        let back: ClipId = serde_json::from_str(&json).expect("deserialize");
        assert_eq!(back, id);
    }
}
