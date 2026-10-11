extension RockstarLauncher {
    /// Red Dead Redemption 2's `system.xml` as tested on a 14" MacBook Pro (M4, 16 GB): DirectX 12 on
    /// D3DMetal 3.0, Fullscreen, Ultra textures, High shadows, reflections, lighting and tessellation,
    /// Medium water, volumetrics and most of the rest, and DLSS (MetalFX through D3DMetal). About
    /// 50 FPS at the 1512×982 desktop, 25 with Retina mode (2026-10-11). Written only before the
    /// game's first launch, so a player's own settings are never replaced.
    ///
    /// Left out so the game fills them in for each Mac: the refresh rate and the adapter's name. The
    /// screen size is the tested Mac's; `fitWindow` replaces it with each Mac's desktop on the first
    /// launch.
    ///
    /// To update: copy `Documents/Rockstar Games/Red Dead Redemption 2/Settings/system.xml` from a
    /// bottle where the new settings were tested, and leave out the same lines.
    static let rdr2TestedSettings = #"""
        <?xml version="1.0" encoding="UTF-8"?>

        <rage__fwuiSystemSettingsCollection>
          <version value="37" />
          <configSource>kSettingsConfig_Safe</configSource>
          <graphics>
            <tessellation>kSettingLevel_High</tessellation>
            <shadowQuality>kSettingLevel_High</shadowQuality>
            <farShadowQuality>kSettingLevel_Medium</farShadowQuality>
            <reflectionQuality>kSettingLevel_High</reflectionQuality>
            <mirrorQuality>kSettingLevel_Low</mirrorQuality>
            <ssao>kSettingLevel_Medium</ssao>
            <textureQuality>kSettingLevel_Ultra</textureQuality>
            <particleQuality>kSettingLevel_Medium</particleQuality>
            <waterQuality>kSettingLevel_Medium</waterQuality>
            <volumetricsQuality>kSettingLevel_Medium</volumetricsQuality>
            <lightingQuality>kSettingLevel_High</lightingQuality>
            <ambientLightingQuality>kSettingLevel_Medium</ambientLightingQuality>
            <anisotropicFiltering value="3" />
            <dlssIndex value="3" />
            <dlssQuality value="2" />
            <dlssSharpen value="0.700000" />
            <fsr2Index value="0" />
            <fsr2Sharpen value="0.350000" />
            <taa>kSettingLevel_High</taa>
            <fxaaEnabled value="false" />
            <msaa value="0" />
            <graphicsQualityPreset value="1.000000" />
            <hdr value="true" />
            <hdr10PlusGaming value="true" />
            <hdrIntensity value="120" />
            <hdrPeakBrightness value="300" />
            <hdrFilmicMode value="false" />
            <gamma value="15" />
            <hdrSettingsMigrated value="true" />
          </graphics>
          <advancedGraphics>
            <API>kSettingAPI_DX12</API>
            <locked value="true" />
            <asyncComputeEnabled value="false" />
            <transferQueuesEnabled value="false" />
            <shadowSoftShadows>kSettingLevel_Low</shadowSoftShadows>
            <motionBlur value="false" />
            <motionBlurLimit value="16.000000" />
            <particleLightingQuality>kSettingLevel_Medium</particleLightingQuality>
            <waterReflectionSSR value="true" />
            <waterRefractionQuality>kSettingLevel_Medium</waterRefractionQuality>
            <waterReflectionQuality>kSettingLevel_Medium</waterReflectionQuality>
            <waterSimulationQuality value="2" />
            <waterLightingQuality>kSettingLevel_High</waterLightingQuality>
            <furDisplayQuality>kSettingLevel_Medium</furDisplayQuality>
            <maxTexUpgradesPerFrame value="5" />
            <shadowGrassShadows>kSettingLevel_Low</shadowGrassShadows>
            <shadowParticleShadows value="false" />
            <shadowLongShadows value="false" />
            <directionalShadowsAlpha value="false" />
            <worldHeightShadowQuality value="0.330000" />
            <directionalScreenSpaceShadowQuality value="0.330000" />
            <ambientMaskVolumesHighPrecision value="false" />
            <scatteringVolumeQuality>kSettingLevel_Medium</scatteringVolumeQuality>
            <volumetricsRaymarchQuality>kSettingLevel_Medium</volumetricsRaymarchQuality>
            <volumetricsLightingQuality>kSettingLevel_Medium</volumetricsLightingQuality>
            <volumetricsRaymarchResolutionUnclamped value="false" />
            <terrainShadowQuality>kSettingLevel_Medium</terrainShadowQuality>
            <damageModelsDisabled value="true" />
            <decalQuality>kSettingLevel_Low</decalQuality>
            <ssaoFullScreenEnabled value="false" />
            <ssaoType value="0" />
            <ssdoSampleCount value="4" />
            <ssdoUseDualRadii value="false" />
            <ssdoResolution>kSettingLevel_Low</ssdoResolution>
            <ssdoTAABlendEnabled value="true" />
            <ssroSampleCount value="2" />
            <snowGlints value="true" />
            <POMQuality>kSettingLevel_Low</POMQuality>
            <probeRelightEveryFrame value="false" />
            <scalingMode>kSettingScale_Mode1o1</scalingMode>
            <reflectionMSAA value="0" />
            <lodScale value="0.750000" />
            <grassLod value="0.500000" />
            <pedLodBias value="0.000000" />
            <vehicleLodBias value="0.000000" />
            <sharpenIntensity value="0.000000" />
            <treeQuality>kSettingLevel_Low</treeQuality>
            <deepsurfaceQuality>kSettingLevel_Low</deepsurfaceQuality>
            <treeTessellationEnabled value="false" />
          </advancedGraphics>
          <video>
            <adapterIndex value="0" />
            <outputIndex value="0" />
            <resolutionIndex value="0" />
            <screenWidth value="1512" />
            <screenHeight value="982" />
            <resolutionIndexWindowed value="0" />
            <screenWidthWindowed value="1512" />
            <screenHeightWindowed value="982" />
            <windowed value="0" />
            <vSync value="0" />
            <tripleBuffered value="false" />
            <ReflexSettings>kSettingReflex_Off</ReflexSettings>
            <pauseOnFocusLoss value="false" />
            <constrainMousePointer value="false" />
          </video>
        </rage__fwuiSystemSettingsCollection>

        """#
}
