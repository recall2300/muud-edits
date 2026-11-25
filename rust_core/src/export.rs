//! 내보내기 설정과 플랫폼별 인코더/ffmpeg 인자 계획.
//!
//! ## 제품 원칙
//! muud-edits의 내보내기에는 **워터마크가 없다**. [`ExportSettings::watermark`]
//! 필드는 이 원칙을 구조적으로 지키기 위한 잠금장치로, `true`면
//! [`ExportError::WatermarkNotAllowed`]로 거부된다. 렌더 파이프라인 어디에도
//! 워터마크 필터를 넣는 경로가 없다.
//!
//! ## 이 모듈이 하는 일 / 하지 않는 일
//! * 한다: 설정 검증, 플랫폼별 하드웨어 인코더 선택, 실행 계획(인자) 생성.
//! * 하지 않는다: 실제 인코딩. 인코딩은 플랫폼 네이티브 API(또는 FFmpeg 폴백)가 한다.
//!
//! 이렇게 분리해 두면 UI가 "내보내기"를 누르기 전에 계획을 보여주고,
//! 사용자는 인코딩 전에 어떤 코덱/비트레이트로 나갈지 확인할 수 있다.

use serde::{Deserialize, Serialize};

use crate::error::ExportError;
use crate::model::Resolution;
use crate::platform::Platform;

fn default_fps() -> u32 {
    30
}
fn default_bitrate() -> u32 {
    8_000
}
fn default_audio_bitrate() -> u32 {
    192
}
fn default_gop() -> u32 {
    60
}
/// 비디오 코덱.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum VideoCodec {
    #[default]
    H264,
    Hevc,
    Av1,
    Vp9,
    ProRes,
}

impl VideoCodec {
    pub fn as_str(self) -> &'static str {
        match self {
            VideoCodec::H264 => "h264",
            VideoCodec::Hevc => "hevc",
            VideoCodec::Av1 => "av1",
            VideoCodec::Vp9 => "vp9",
            VideoCodec::ProRes => "prores",
        }
    }

    /// 4:2:0으로 떨어뜨릴 때 짝수 해상도가 필요한가.
    pub fn requires_even_dimensions(self) -> bool {
        matches!(self, VideoCodec::H264 | VideoCodec::Hevc)
    }

    /// 이 코덱에 맞는 기본 픽셀 포맷.
    pub fn pixel_format(self, ten_bit: bool) -> &'static str {
        match (self, ten_bit) {
            (VideoCodec::ProRes, _) => "yuv422p10le",
            (VideoCodec::Hevc, true) => "yuv420p10le",
            (VideoCodec::Av1, true) => "yuv420p10le",
            _ => "yuv420p",
        }
    }
}

/// 오디오 코덱.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum AudioCodec {
    #[default]
    Aac,
    Opus,
    PcmS16Le,
}

impl AudioCodec {
    pub fn as_str(self) -> &'static str {
        match self {
            AudioCodec::Aac => "aac",
            AudioCodec::Opus => "opus",
            AudioCodec::PcmS16Le => "pcm_s16le",
        }
    }

    /// ffmpeg 인코더 이름.
    pub fn ffmpeg_encoder(self) -> &'static str {
        match self {
            AudioCodec::Aac => "aac",
            AudioCodec::Opus => "libopus",
            AudioCodec::PcmS16Le => "pcm_s16le",
        }
    }

    /// 비트레이트 인자가 의미 있는가.
    pub fn uses_bitrate(self) -> bool {
        !matches!(self, AudioCodec::PcmS16Le)
    }
}

/// 컨테이너.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Container {
    #[default]
    Mp4,
    Mov,
    WebM,
}

impl Container {
    pub fn extension(self) -> &'static str {
        match self {
            Container::Mp4 => "mp4",
            Container::Mov => "mov",
            Container::WebM => "webm",
        }
    }

    pub fn as_str(self) -> &'static str {
        match self {
            Container::Mp4 => "mp4",
            Container::Mov => "mov",
            Container::WebM => "webm",
        }
    }
}

/// 하드웨어 가속 백엔드 선택.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
pub enum HwAccel {
    /// 플랫폼 기본 백엔드(있으면) 사용, 없으면 소프트웨어.
    #[default]
    #[serde(rename = "auto")]
    Auto,
    /// 항상 소프트웨어 인코더(libx264 등). 디버깅/호환성용.
    #[serde(rename = "software")]
    Software,
    #[serde(rename = "videotoolbox")]
    VideoToolbox,
    #[serde(rename = "mediafoundation")]
    MediaFoundation,
    #[serde(rename = "mediacodec")]
    MediaCodec,
    #[serde(rename = "nvenc")]
    Nvenc,
    #[serde(rename = "qsv")]
    Qsv,
    #[serde(rename = "vaapi")]
    Vaapi,
}

impl HwAccel {
    pub fn as_str(self) -> &'static str {
        match self {
            HwAccel::Auto => "auto",
            HwAccel::Software => "software",
            HwAccel::VideoToolbox => "videotoolbox",
            HwAccel::MediaFoundation => "mediafoundation",
            HwAccel::MediaCodec => "mediacodec",
            HwAccel::Nvenc => "nvenc",
            HwAccel::Qsv => "qsv",
            HwAccel::Vaapi => "vaapi",
        }
    }
}

/// 내보낼 구간(선택). 없으면 전체 타임라인.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct ExportRange {
    pub start_ms: i64,
    pub end_ms: i64,
}

impl ExportRange {
    pub fn duration_ms(&self) -> i64 {
        self.end_ms - self.start_ms
    }
}

/// 선택된 인코더.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct EncoderChoice {
    /// ffmpeg 인코더 이름(예: `h264_videotoolbox`). 네이티브 경로에서는 힌트로 쓴다.
    pub name: String,
    pub hardware: bool,
    pub backend: HwAccel,
    pub notes: String,
}

/// 내보내기 설정.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct ExportSettings {
    #[serde(default)]
    pub resolution: Resolution,
    #[serde(default = "default_fps")]
    pub fps: u32,
    #[serde(default = "default_bitrate")]
    pub video_bitrate_kbps: u32,
    #[serde(default)]
    pub max_bitrate_kbps: Option<u32>,
    #[serde(default = "default_gop")]
    pub gop_frames: u32,
    #[serde(default)]
    pub codec: VideoCodec,
    #[serde(default)]
    pub audio_codec: AudioCodec,
    #[serde(default = "default_audio_bitrate")]
    pub audio_bitrate_kbps: u32,
    #[serde(default)]
    pub container: Container,
    #[serde(default)]
    pub hardware: HwAccel,
    #[serde(default)]
    pub range: Option<ExportRange>,
    /// 제품 원칙상 항상 false. true면 검증에서 거부된다.
    #[serde(default)]
    pub watermark: bool,
    /// 10bit 파이프라인 사용 여부(HEVC/AV1/ProRes에서만 의미).
    #[serde(default)]
    pub ten_bit: bool,
    /// 자막을 영상에 구워 넣을지(번인). 기본 true.
    #[serde(default = "default_true")]
    pub burn_in_subtitles: bool,
}

fn default_true() -> bool {
    true
}

impl Default for ExportSettings {
    fn default() -> Self {
        Self {
            resolution: Resolution::VERTICAL_1080P,
            fps: default_fps(),
            video_bitrate_kbps: default_bitrate(),
            max_bitrate_kbps: None,
            gop_frames: default_gop(),
            codec: VideoCodec::H264,
            audio_codec: AudioCodec::Aac,
            audio_bitrate_kbps: default_audio_bitrate(),
            container: Container::Mp4,
            hardware: HwAccel::Auto,
            range: None,
            watermark: false,
            ten_bit: false,
            burn_in_subtitles: true,
        }
    }
}

impl ExportSettings {
    /// 프로젝트 해상도/fps에 맞춘 기본 설정. 숏폼(1080x1920, 30fps)이면 약 8Mbps.
    pub fn for_project(resolution: Resolution, fps: u32) -> Self {
        let fps = fps.max(1);
        let estimated =
            (resolution.pixels() as f64 * f64::from(fps) * 0.13 / 1000.0).round() as u32;
        Self {
            resolution,
            fps,
            video_bitrate_kbps: estimated.clamp(1_500, 40_000),
            gop_frames: (fps * 2).max(1),
            ..Self::default()
        }
    }

    /// 플랫폼과 무관한 설정 검증.
    pub fn validate(&self) -> Result<(), ExportError> {
        if self.watermark {
            return Err(ExportError::WatermarkNotAllowed);
        }
        if self.resolution.width < 2 || self.resolution.height < 2 {
            return Err(ExportError::InvalidResolution {
                width: self.resolution.width,
                height: self.resolution.height,
            });
        }
        if self.resolution.width > 7680 || self.resolution.height > 7680 {
            return Err(ExportError::InvalidResolution {
                width: self.resolution.width,
                height: self.resolution.height,
            });
        }
        if self.codec.requires_even_dimensions() && !self.resolution.is_even() {
            return Err(ExportError::OddDimensions {
                codec: self.codec.as_str().to_string(),
                width: self.resolution.width,
                height: self.resolution.height,
            });
        }
        if self.fps == 0 || self.fps > 120 {
            return Err(ExportError::InvalidFrameRate { fps: self.fps });
        }
        if self.video_bitrate_kbps < 100 || self.video_bitrate_kbps > 200_000 {
            return Err(ExportError::InvalidBitrate {
                kbps: self.video_bitrate_kbps,
            });
        }
        if let Some(max) = self.max_bitrate_kbps {
            if max < self.video_bitrate_kbps {
                return Err(ExportError::InvalidBitrate { kbps: max });
            }
        }
        if let Some(range) = self.range {
            if range.start_ms < 0 || range.start_ms >= range.end_ms {
                return Err(ExportError::InvalidResolution {
                    width: self.resolution.width,
                    height: self.resolution.height,
                });
            }
        }
        self.validate_container_codec()
    }

    fn validate_container_codec(&self) -> Result<(), ExportError> {
        let ok = match (self.container, self.codec, self.audio_codec) {
            (Container::WebM, VideoCodec::Vp9 | VideoCodec::Av1, AudioCodec::Opus) => true,
            (Container::WebM, _, _) => false,
            (Container::Mov, VideoCodec::ProRes, AudioCodec::Aac | AudioCodec::PcmS16Le) => true,
            (Container::Mov, VideoCodec::ProRes, _) => false,
            (Container::Mov, _, AudioCodec::PcmS16Le) => true,
            (Container::Mov, _, _) => true,
            (Container::Mp4, VideoCodec::ProRes, _) => false,
            (Container::Mp4, _, AudioCodec::PcmS16Le) => false,
            (Container::Mp4, _, _) => true,
        };
        if ok {
            Ok(())
        } else {
            Err(ExportError::UnsupportedCombination {
                container: self.container.as_str().to_string(),
                codec: format!("{}/{}", self.codec.as_str(), self.audio_codec.as_str()),
            })
        }
    }

    /// 플랫폼까지 포함한 검증(하드웨어 백엔드 지원 여부, 최대 해상도).
    pub fn validate_for(&self, platform: Platform) -> Result<(), ExportError> {
        self.validate()?;
        let caps = platform.capabilities();
        if self.resolution.width > caps.max_resolution.width
            || self.resolution.height > caps.max_resolution.height
        {
            return Err(ExportError::InvalidResolution {
                width: self.resolution.width,
                height: self.resolution.height,
            });
        }
        if !platform.supports_hw_accel(self.hardware) && self.hardware != HwAccel::Auto {
            return Err(ExportError::UnsupportedCombination {
                container: platform.id().to_string(),
                codec: format!("hw:{}", self.hardware.as_str()),
            });
        }
        Ok(())
    }

    /// 이 플랫폼에서 실제로 쓸 인코더.
    ///
    /// 요청한 백엔드가 불가능하면 소프트웨어로 조용히 폴백하지 않고,
    /// [`EncoderChoice::notes`]에 이유를 남긴다(UI가 경고로 보여준다).
    pub fn encoder_for(&self, platform: Platform) -> EncoderChoice {
        let caps = platform.capabilities();

        let (backend, requested) = match self.hardware {
            HwAccel::Auto => {
                if caps.can_encode(self.codec) {
                    (platform.native_backend(), true)
                } else {
                    (HwAccel::Software, true)
                }
            }
            HwAccel::Software => (HwAccel::Software, true),
            explicit => {
                // 명시적 백엔드는 "플랫폼이 그 백엔드를 제공하는가" + "그 백엔드에 해당 코덱 인코더가 있는가"로 판단한다.
                // 하드웨어 실제 지원 여부(드라이버/기기)는 런타임 확인 몫이므로 계획 단계에서는 낙관적으로 잡는다.
                if platform.supports_hw_accel(explicit)
                    && encoder_name(explicit, self.codec).is_some()
                {
                    (explicit, true)
                } else {
                    (HwAccel::Software, false)
                }
            }
        };

        let name = match backend {
            HwAccel::Software => software_encoder(self.codec),
            other => {
                encoder_name(other, self.codec).unwrap_or_else(|| software_encoder(self.codec))
            }
        };

        let hardware = backend != HwAccel::Software;
        let notes = if requested {
            if hardware {
                format!(
                    "{} 하드웨어 인코더 사용 ({} {})",
                    platform.id(),
                    backend.as_str(),
                    self.codec.as_str()
                )
            } else {
                format!(
                    "{} 소프트웨어 인코더 사용(요청: {})",
                    platform.id(),
                    self.hardware.as_str()
                )
            }
        } else {
            format!(
                "요청한 {} 백엔드/코덱 조합을 {}에서 쓸 수 없어 소프트웨어로 폴백",
                self.hardware.as_str(),
                platform.id()
            )
        };

        EncoderChoice {
            name: name.to_string(),
            hardware,
            backend,
            notes,
        }
    }

    /// 비디오 필터 체인(스케일 + (선택) 하드웨어 업로드).
    fn video_filter(&self, encoder: &EncoderChoice, ten_bit: bool) -> String {
        let mut chain = format!(
            "scale={}:{}:flags=bicubic",
            self.resolution.width, self.resolution.height
        );
        match encoder.backend {
            HwAccel::Vaapi => {
                let fmt = if ten_bit { "p010" } else { "nv12" };
                chain.push_str(&format!(",format={fmt},hwupload"));
            }
            HwAccel::Qsv => {
                let fmt = if ten_bit { "p010le" } else { "nv12" };
                chain.push_str(&format!(",format={fmt}"));
            }
            _ => {}
        }
        chain
    }

    /// ffmpeg 인수 목록(폴백 경로). 네이티브 인코더 경로에서는 참고용 계획서로 쓴다.
    pub fn ffmpeg_args(&self, platform: Platform, input: &str, output: &str) -> Vec<String> {
        let encoder = self.encoder_for(platform);
        let ten_bit = self.ten_bit
            && matches!(
                self.codec,
                VideoCodec::Hevc | VideoCodec::Av1 | VideoCodec::ProRes
            );

        let mut args: Vec<String> = vec!["-hide_banner".into(), "-y".into()];

        if let Some(range) = self.range {
            args.push("-ss".into());
            args.push(format!("{:.3}", range.start_ms as f64 / 1000.0));
            args.push("-to".into());
            args.push(format!("{:.3}", range.end_ms as f64 / 1000.0));
        }

        args.push("-i".into());
        args.push(input.to_string());

        // --- video ---
        if encoder.backend == HwAccel::Vaapi {
            args.push("-vaapi_device".into());
            args.push("/dev/dri/renderD128".into());
        }
        args.push("-c:v".into());
        args.push(encoder.name.clone());

        match self.codec {
            VideoCodec::ProRes => {
                args.push("-profile:v".into());
                args.push("3".into()); // Apple ProRes 422
                args.push("-pix_fmt".into());
                args.push("yuv422p10le".into());
            }
            _ => {
                args.push("-b:v".into());
                args.push(format!("{}k", self.video_bitrate_kbps));
                if let Some(max) = self.max_bitrate_kbps {
                    args.push("-maxrate".into());
                    args.push(format!("{max}k"));
                    args.push("-bufsize".into());
                    args.push(format!("{}k", u64::from(max) * 2));
                }
                if encoder.backend == HwAccel::Auto || encoder.backend == HwAccel::Software {
                    args.push("-pix_fmt".into());
                    args.push(self.codec.pixel_format(ten_bit).to_string());
                }
            }
        }

        args.push("-vf".into());
        args.push(self.video_filter(&encoder, ten_bit));
        args.push("-r".into());
        args.push(self.fps.to_string());
        args.push("-g".into());
        args.push(self.gop_frames.max(1).to_string());

        // --- audio ---
        args.push("-c:a".into());
        args.push(self.audio_codec.ffmpeg_encoder().to_string());
        if self.audio_codec.uses_bitrate() {
            args.push("-b:a".into());
            args.push(format!("{}k", self.audio_bitrate_kbps));
        }
        if self.audio_codec == AudioCodec::Opus {
            args.push("-ar".into());
            args.push("48000".into());
        }

        if self.container == Container::Mp4 {
            args.push("-movflags".into());
            args.push("+faststart".into());
        }

        args.push(output.to_string());
        args
    }

    /// 사람이 복사/붙여넣기 할 수 있는 명령줄 문자열.
    pub fn ffmpeg_command_line(&self, platform: Platform, input: &str, output: &str) -> String {
        let mut parts = vec!["ffmpeg".to_string()];
        for arg in self.ffmpeg_args(platform, input, output) {
            if arg.is_empty() || arg.contains(' ') || arg.contains('"') {
                parts.push(format!("\"{}\"", arg.replace('"', "\\\"")));
            } else {
                parts.push(arg);
            }
        }
        parts.join(" ")
    }

    /// 내보내기 계획서(UI 미리보기 + 로그용).
    pub fn plan(&self, platform: Platform, input: &str, output: &str) -> ExportPlan {
        let encoder = self.encoder_for(platform);
        let mut notes = Vec::new();
        notes.push(encoder.notes.clone());
        notes.push(format!(
            "워터마크 없음: 활성 (요청 값 watermark={})",
            self.watermark
        ));
        if self.ten_bit
            && !matches!(
                self.codec,
                VideoCodec::Hevc | VideoCodec::Av1 | VideoCodec::ProRes
            )
        {
            notes.push(format!(
                "{}는 10bit를 지원하지 않아 8bit로 내보냅니다",
                self.codec.as_str()
            ));
        }
        let caps = platform.capabilities();
        notes.push(format!(
            "{} 네이티브 경로: {} / 합성: {}",
            caps.display_name, caps.media_api, caps.compositor
        ));

        ExportPlan {
            platform: platform.id().to_string(),
            container: self.container.as_str().to_string(),
            codec: self.codec.as_str().to_string(),
            audio_codec: self.audio_codec.as_str().to_string(),
            resolution: self.resolution,
            fps: self.fps,
            video_bitrate_kbps: self.video_bitrate_kbps,
            output_extension: self.container.extension().to_string(),
            encoder,
            ffmpeg_args: self.ffmpeg_args(platform, input, output),
            ffmpeg_command: self.ffmpeg_command_line(platform, input, output),
            watermark: false,
            notes,
        }
    }
}

/// 플랫폼별 네이티브 하드웨어 인코더 이름.
fn encoder_name(backend: HwAccel, codec: VideoCodec) -> Option<&'static str> {
    let name = match (backend, codec) {
        (HwAccel::VideoToolbox, VideoCodec::H264) => "h264_videotoolbox",
        (HwAccel::VideoToolbox, VideoCodec::Hevc) => "hevc_videotoolbox",
        (HwAccel::VideoToolbox, VideoCodec::ProRes) => "prores_videotoolbox",
        (HwAccel::MediaFoundation, VideoCodec::H264) => "h264_mf",
        (HwAccel::MediaFoundation, VideoCodec::Hevc) => "hevc_mf",
        (HwAccel::MediaCodec, VideoCodec::H264) => "h264_mediacodec",
        (HwAccel::MediaCodec, VideoCodec::Hevc) => "hevc_mediacodec",
        (HwAccel::MediaCodec, VideoCodec::Vp9) => "vp9_mediacodec",
        (HwAccel::MediaCodec, VideoCodec::Av1) => "av1_mediacodec",
        (HwAccel::Nvenc, VideoCodec::H264) => "h264_nvenc",
        (HwAccel::Nvenc, VideoCodec::Hevc) => "hevc_nvenc",
        (HwAccel::Nvenc, VideoCodec::Av1) => "av1_nvenc",
        (HwAccel::Qsv, VideoCodec::H264) => "h264_qsv",
        (HwAccel::Qsv, VideoCodec::Hevc) => "hevc_qsv",
        (HwAccel::Qsv, VideoCodec::Av1) => "av1_qsv",
        (HwAccel::Vaapi, VideoCodec::H264) => "h264_vaapi",
        (HwAccel::Vaapi, VideoCodec::Hevc) => "hevc_vaapi",
        (HwAccel::Vaapi, VideoCodec::Av1) => "av1_vaapi",
        _ => return None,
    };
    Some(name)
}

/// 소프트웨어(항상 available) 인코더.
fn software_encoder(codec: VideoCodec) -> &'static str {
    match codec {
        VideoCodec::H264 => "libx264",
        VideoCodec::Hevc => "libx265",
        VideoCodec::Av1 => "libsvtav1",
        VideoCodec::Vp9 => "libvpx-vp9",
        VideoCodec::ProRes => "prores_ks",
    }
}

/// 내보내기 계획서.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct ExportPlan {
    pub platform: String,
    pub container: String,
    pub codec: String,
    pub audio_codec: String,
    pub resolution: Resolution,
    pub fps: u32,
    pub video_bitrate_kbps: u32,
    pub output_extension: String,
    pub encoder: EncoderChoice,
    pub ffmpeg_args: Vec<String>,
    pub ffmpeg_command: String,
    pub watermark: bool,
    pub notes: Vec<String>,
}

impl ExportPlan {
    /// 렌더러에 넘길 요약 한 줄.
    pub fn summary(&self) -> String {
        format!(
            "{} {}x{}@{} · {} ({}) · {}kbps · 워터마크 없음",
            self.container,
            self.resolution.width,
            self.resolution.height,
            self.fps,
            self.codec,
            self.encoder.name,
            self.video_bitrate_kbps
        )
    }

    /// 워터마크 관련 필터가 계획에 섞여 있지 않은지 확인(회귀 방지).
    pub fn has_watermark_filter(&self) -> bool {
        self.ffmpeg_args
            .iter()
            .any(|a| a.contains("drawtext") || a.contains("watermark") || a.contains("overlay="))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn settings(codec: VideoCodec, container: Container) -> ExportSettings {
        ExportSettings {
            codec,
            container,
            ten_bit: false,
            ..ExportSettings::for_project(Resolution::VERTICAL_1080P, 30)
        }
    }

    #[test]
    fn project_defaults_are_social_ready() {
        let s = ExportSettings::for_project(Resolution::VERTICAL_1080P, 30);
        assert_eq!(s.resolution, Resolution::new(1080, 1920));
        assert_eq!(s.fps, 30);
        assert_eq!(s.gop_frames, 60);
        assert!(s.video_bitrate_kbps >= 6_000 && s.video_bitrate_kbps <= 10_000);
        assert!(!s.watermark, "기본값은 항상 워터마크 없음");
        assert!(s.validate().is_ok());
    }

    #[test]
    fn watermark_is_rejected() {
        let mut s = ExportSettings::default();
        s.watermark = true;
        assert_eq!(s.validate(), Err(ExportError::WatermarkNotAllowed));
    }

    #[test]
    fn odd_dimensions_rejected_for_h264() {
        let mut s = ExportSettings::default();
        s.resolution = Resolution::new(1081, 1921);
        assert!(matches!(
            s.validate(),
            Err(ExportError::OddDimensions { .. })
        ));
        s.codec = VideoCodec::ProRes;
        s.container = Container::Mov;
        assert!(s.validate().is_ok(), "ProRes는 홀수 해상도 허용");
    }

    #[test]
    fn hardware_encoder_selection_per_platform() {
        let s = settings(VideoCodec::H264, Container::Mp4);
        assert_eq!(s.encoder_for(Platform::MacOs).name, "h264_videotoolbox");
        assert_eq!(s.encoder_for(Platform::Ios).name, "h264_videotoolbox");
        assert_eq!(s.encoder_for(Platform::Windows).name, "h264_mf");
        assert_eq!(s.encoder_for(Platform::Android).name, "h264_mediacodec");
        assert!(s.encoder_for(Platform::MacOs).hardware);
    }

    #[test]
    fn hevc_uses_platform_hevc_encoders() {
        let s = settings(VideoCodec::Hevc, Container::Mp4);
        assert_eq!(s.encoder_for(Platform::MacOs).name, "hevc_videotoolbox");
        assert_eq!(s.encoder_for(Platform::Windows).name, "hevc_mf");
        assert_eq!(s.encoder_for(Platform::Android).name, "hevc_mediacodec");
    }

    #[test]
    fn av1_falls_back_to_software_where_unsupported() {
        let s = settings(VideoCodec::Av1, Container::Mp4);
        let mac = s.encoder_for(Platform::MacOs);
        assert_eq!(mac.name, "libsvtav1");
        assert!(!mac.hardware);
        // Android는 AV1 디코드만 하드웨어이고 인코드는 기기 편차가 커서 소프트웨어로 계획한다.
        let android = s.encoder_for(Platform::Android);
        assert_eq!(android.name, "libsvtav1");
        assert!(!android.hardware);
    }

    #[test]
    fn av1_explicit_hw_backend_works_where_supported() {
        let mut s = settings(VideoCodec::Av1, Container::Mp4);
        s.hardware = HwAccel::Nvenc;
        let windows = s.encoder_for(Platform::Windows);
        assert_eq!(windows.name, "av1_nvenc");
        assert!(windows.hardware);
        assert!(s.validate_for(Platform::Windows).is_ok());
    }

    #[test]
    fn software_request_wins() {
        let mut s = settings(VideoCodec::H264, Container::Mp4);
        s.hardware = HwAccel::Software;
        let e = s.encoder_for(Platform::MacOs);
        assert_eq!(e.name, "libx264");
        assert!(!e.hardware);
    }

    #[test]
    fn impossible_backend_is_reported() {
        let mut s = settings(VideoCodec::H264, Container::Mp4);
        s.hardware = HwAccel::Vaapi; // macOS에서 불가
        let e = s.encoder_for(Platform::MacOs);
        assert_eq!(e.backend, HwAccel::Software);
        assert!(e.notes.contains("폴백"));
        assert!(s.validate_for(Platform::MacOs).is_err());
    }

    #[test]
    fn webm_requires_opus_and_vp9_or_av1() {
        let good = settings(VideoCodec::Vp9, Container::WebM);
        let mut good = good;
        good.audio_codec = AudioCodec::Opus;
        assert!(good.validate().is_ok());

        let bad = settings(VideoCodec::H264, Container::WebM);
        assert!(matches!(
            bad.validate(),
            Err(ExportError::UnsupportedCombination { .. })
        ));
    }

    #[test]
    fn prores_only_in_mov() {
        let mut s = settings(VideoCodec::ProRes, Container::Mp4);
        assert!(s.validate().is_err());
        s.container = Container::Mov;
        assert!(s.validate().is_ok());
    }

    #[test]
    fn ffmpeg_args_have_no_watermark_filter() {
        for codec in [
            VideoCodec::H264,
            VideoCodec::Hevc,
            VideoCodec::Av1,
            VideoCodec::ProRes,
        ] {
            let container = if codec == VideoCodec::ProRes {
                Container::Mov
            } else {
                Container::Mp4
            };
            let plan = settings(codec, container).plan(Platform::MacOs, "/in.mp4", "/out.mov");
            assert!(!plan.has_watermark_filter(), "워터마크 필터가 없어야 한다");
            assert!(!plan.watermark);
            assert!(plan.ffmpeg_command.starts_with("ffmpeg "));
        }
    }

    #[test]
    fn ffmpeg_args_include_scale_and_faststart() {
        let args = settings(VideoCodec::H264, Container::Mp4).ffmpeg_args(
            Platform::MacOs,
            "/in.mp4",
            "/out.mp4",
        );
        let joined = args.join(" ");
        assert!(joined.contains("-c:v h264_videotoolbox"));
        assert!(joined.contains("scale=1080:1920"));
        assert!(joined.contains("-movflags +faststart"));
        assert!(joined.contains("-c:a aac"));
        assert_eq!(args.last().unwrap(), "/out.mp4");
    }

    #[test]
    fn range_adds_seek_arguments() {
        let mut s = settings(VideoCodec::H264, Container::Mp4);
        s.range = Some(ExportRange {
            start_ms: 1_500,
            end_ms: 4_000,
        });
        let args = s.ffmpeg_args(Platform::MacOs, "/in.mp4", "/out.mp4");
        let joined = args.join(" ");
        assert!(joined.contains("-ss 1.500"));
        assert!(joined.contains("-to 4.000"));
    }

    #[test]
    fn plan_summary_is_readable() {
        let plan = settings(VideoCodec::H264, Container::Mp4).plan(
            Platform::Android,
            "/in.mp4",
            "/out.mp4",
        );
        assert_eq!(plan.output_extension, "mp4");
        assert!(plan.summary().contains("1080x1920"));
        assert!(plan.notes.iter().any(|n| n.contains("워터마크 없음")));
    }
}
