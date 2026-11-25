//! 플랫폼 식별과 미디어/GPU 역량 표.
//!
//! 같은 [`crate::export::ExportSettings`]라도 플랫폼마다 실제 인코더와
//! 미디어 API가 다르다. 이 모듈은 "무엇을 쓸 수 있는가"만 알고,
//! "어떻게 명령을 만드는가"는 `export` 모듈이 담당한다.
//!
//! | 플랫폼 | 디코드 | 인코드 | 합성 | Flutter 연결 |
//! |---|---|---|---|---|
//! | macOS | VideoToolbox/AVFoundation | VideoToolbox | Metal | Flutter macOS embedder + texture |
//! | Windows | Media Foundation (D3D11) | Media Foundation | D3D11 | Flutter Windows embedder + texture |
//! | Android | MediaCodec + Surface | MediaCodec | OpenGL ES/Vulkan | Flutter Texture (ExternalTexture) |
//! | iOS | AVFoundation | VideoToolbox | Metal | Flutter Texture |
//! | Linux(개발용) | VAAPI/NVDEC + FFmpeg | VAAPI/NVENC | Vulkan/GL | Flutter Linux embedder |

use serde::{Deserialize, Serialize};

use crate::export::{HwAccel, VideoCodec};
use crate::model::Resolution;

/// 지원 대상 플랫폼. `Linux`는 데스크톱 개발/CI용 베스트에포트.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub enum Platform {
    #[serde(rename = "macos")]
    MacOs,
    #[serde(rename = "windows")]
    Windows,
    #[serde(rename = "android")]
    Android,
    #[serde(rename = "ios")]
    Ios,
    #[serde(rename = "linux")]
    Linux,
}

impl Platform {
    pub const ALL: [Platform; 5] = [
        Platform::MacOs,
        Platform::Windows,
        Platform::Android,
        Platform::Ios,
        Platform::Linux,
    ];

    /// UI/설정에서 쓰는 문자열 id.
    pub fn id(self) -> &'static str {
        match self {
            Platform::MacOs => "macos",
            Platform::Windows => "windows",
            Platform::Android => "android",
            Platform::Ios => "ios",
            Platform::Linux => "linux",
        }
    }

    pub fn from_id(text: &str) -> Option<Self> {
        match text.trim().to_ascii_lowercase().as_str() {
            "macos" | "mac" | "osx" | "darwin" => Some(Platform::MacOs),
            "windows" | "win" | "win32" => Some(Platform::Windows),
            "android" => Some(Platform::Android),
            "ios" => Some(Platform::Ios),
            "linux" => Some(Platform::Linux),
            _ => None,
        }
    }

    /// 지금 이 코드가 도는 플랫폼.
    pub fn current() -> Self {
        if cfg!(target_os = "macos") {
            Platform::MacOs
        } else if cfg!(target_os = "windows") {
            Platform::Windows
        } else if cfg!(target_os = "android") {
            Platform::Android
        } else if cfg!(target_os = "ios") {
            Platform::Ios
        } else {
            Platform::Linux
        }
    }

    /// 하드웨어 가속을 요청했을 때 기본으로 쓸 백엔드.
    ///
    /// Linux는 배포 대상이 아니므로 `Auto`에서도 소프트웨어(FFmpeg)를 쓴다.
    /// VAAPI/NVENC는 명시적으로 요청할 때만 선택된다.
    pub fn native_backend(self) -> HwAccel {
        match self {
            Platform::MacOs | Platform::Ios => HwAccel::VideoToolbox,
            Platform::Windows => HwAccel::MediaFoundation,
            Platform::Android => HwAccel::MediaCodec,
            Platform::Linux => HwAccel::Software,
        }
    }

    /// 해당 백엔드를 이 플랫폼에서 쓸 수 있는가.
    pub fn supports_hw_accel(self, accel: HwAccel) -> bool {
        match accel {
            HwAccel::Auto | HwAccel::Software => true,
            HwAccel::VideoToolbox => matches!(self, Platform::MacOs | Platform::Ios),
            HwAccel::MediaFoundation => matches!(self, Platform::Windows),
            HwAccel::MediaCodec => matches!(self, Platform::Android),
            HwAccel::Nvenc | HwAccel::Qsv => matches!(self, Platform::Windows | Platform::Linux),
            HwAccel::Vaapi => matches!(self, Platform::Linux),
        }
    }

    /// 플랫폼별 역량 요약. UI 설정 화면과 문서가 같은 표를 쓰도록 한 곳에 둔다.
    pub fn capabilities(self) -> PlatformCapabilities {
        let (display, media_api, compositor, hw_decode, hw_encode, max_res, notes) = match self {
            Platform::MacOs => (
                "macOS",
                "AVFoundation + VideoToolbox",
                "Metal",
                vec![VideoCodec::H264, VideoCodec::Hevc, VideoCodec::ProRes],
                vec![VideoCodec::H264, VideoCodec::Hevc, VideoCodec::ProRes],
                Resolution::new(7680, 4320),
                "Apple Silicon에서 ProRes 인코딩까지 하드웨어. AV1 인코딩은 미지원(디코드만).",
            ),
            Platform::Windows => (
                "Windows",
                "Media Foundation (DXVA/D3D11)",
                "D3D11",
                vec![VideoCodec::H264, VideoCodec::Hevc, VideoCodec::Av1],
                vec![VideoCodec::H264, VideoCodec::Hevc],
                Resolution::new(7680, 4320),
                "코덱 지원은 설치된 MFT(하드웨어 벤더 드라이버)에 의존. NVENC/QSV는 선택적 경로.",
            ),
            Platform::Android => (
                "Android",
                "MediaCodec + MediaExtractor (NDK AMediaCodec)",
                "OpenGL ES 3.x / Vulkan",
                vec![VideoCodec::H264, VideoCodec::Hevc, VideoCodec::Vp9, VideoCodec::Av1],
                vec![VideoCodec::H264, VideoCodec::Hevc],
                Resolution::new(3840, 2160),
                "기기별 인코더 화이트리스트가 필요(제조사/칩셋 편차). 4K는 하이엔드 기기 한정.",
            ),
            Platform::Ios => (
                "iOS",
                "AVFoundation + VideoToolbox",
                "Metal",
                vec![VideoCodec::H264, VideoCodec::Hevc, VideoCodec::ProRes],
                vec![VideoCodec::H264, VideoCodec::Hevc],
                Resolution::new(3840, 2160),
                "ProRes 인코딩은 iPhone 13 Pro 이상 등 일부 기기. 백그라운드 익스포트는 BGProcessingTask 필요.",
            ),
            Platform::Linux => (
                "Linux (개발용)",
                "FFmpeg + VAAPI/NVDEC",
                "Vulkan/OpenGL",
                vec![VideoCodec::H264, VideoCodec::Hevc, VideoCodec::Av1, VideoCodec::Vp9],
                vec![VideoCodec::H264, VideoCodec::Hevc, VideoCodec::Av1],
                Resolution::new(3840, 2160),
                "정식 배포 대상은 아니며 CI/개발 편의용. FFmpeg 소프트웨어 인코더로 폴백.",
            ),
        };

        PlatformCapabilities {
            platform: self,
            display_name: display.to_string(),
            media_api: media_api.to_string(),
            compositor: compositor.to_string(),
            hw_decode,
            hw_encode,
            max_resolution: max_res,
            notes: notes.to_string(),
        }
    }
}

/// 한 플랫폼의 미디어 역량.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct PlatformCapabilities {
    pub platform: Platform,
    pub display_name: String,
    pub media_api: String,
    pub compositor: String,
    pub hw_decode: Vec<VideoCodec>,
    pub hw_encode: Vec<VideoCodec>,
    pub max_resolution: Resolution,
    pub notes: String,
}

impl PlatformCapabilities {
    pub fn can_decode(&self, codec: VideoCodec) -> bool {
        self.hw_decode.contains(&codec)
    }

    pub fn can_encode(&self, codec: VideoCodec) -> bool {
        self.hw_encode.contains(&codec)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn ids_roundtrip() {
        for platform in Platform::ALL {
            assert_eq!(Platform::from_id(platform.id()), Some(platform));
        }
        assert_eq!(Platform::from_id("MAC"), Some(Platform::MacOs));
        assert_eq!(Platform::from_id("beos"), None);
    }

    #[test]
    fn hw_backends_are_platform_scoped() {
        assert!(Platform::MacOs.supports_hw_accel(HwAccel::VideoToolbox));
        assert!(!Platform::Windows.supports_hw_accel(HwAccel::VideoToolbox));
        assert!(Platform::Android.supports_hw_accel(HwAccel::MediaCodec));
        assert!(Platform::Windows.supports_hw_accel(HwAccel::Nvenc));
        assert!(!Platform::Ios.supports_hw_accel(HwAccel::Vaapi));
        assert!(Platform::Linux.supports_hw_accel(HwAccel::Vaapi));
    }

    #[test]
    fn capabilities_match_backends() {
        for platform in Platform::ALL {
            let caps = platform.capabilities();
            assert_eq!(caps.platform, platform);
            assert!(caps.can_encode(VideoCodec::H264));
        }
        assert!(Platform::Android.capabilities().can_decode(VideoCodec::Vp9));
        assert!(!Platform::Ios.capabilities().can_encode(VideoCodec::Av1));
    }

    #[test]
    fn current_platform_is_known() {
        assert!(Platform::ALL.contains(&Platform::current()));
    }
}
