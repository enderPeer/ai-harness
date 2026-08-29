# Idle-production queue for the GLM workers: self-contained drafting tasks,
# outputs to a review folder (nothing lands in the repo unreviewed).
$out = 'C:\Users\end\dev\ember\.claude\worker-drafts'
New-Item -ItemType Directory -Force $out | Out-Null
$repo = 'C:\Users\end\dev\ember'

$tasks = @(
    @{ name = 'hitboxes.rs'; worker = 'specht:8086'; max = 6000; sys = 'Senior Rust gameplay programmer. Output ONLY Rust code.'; files = @("$repo\crates\pong-core\src\shooter.rs");
       prompt = 'Draft a self-contained collider module for this deterministic shooter sim: an enum ColliderShape { Capsule { radius, height }, Aabb { half_extents } } with pure-fn intersection tests (segment vs capsule, segment vs aabb, capsule vs capsule) suitable for hitscan and movement blocking, plus per-part hit multipliers for a humanoid (head 2.0, torso 1.0, limb 0.7) and a fn humanoid_colliders(pos, yaw, scale) -> arrayvec-free Vec of (part, ColliderShape, offset). Deterministic f32 math only, no external crates, no engine deps. Include unit tests.' },
    @{ name = 'arena-layouts.json'; worker = 'specht:8087'; max = 4000; sys = 'Level designer. Output ONLY JSON.'; files = @();
       prompt = 'Design 3 arena layout variants for a 24x24 unit square arena (coordinates -12..12) as JSON: {"layouts":[{"name","props":[{"kind":"crate|barrel|pillar|barricade","x","z","yaw_deg","scale"}]}]}. 8-14 props per layout, leave spawn areas near corners clear, create cover lanes and a contested center. Balanced for 2-8 players.' },
    @{ name = 'lighting-upgrade.wgsl'; worker = 'specht:8086'; max = 5000; sys = 'Senior graphics programmer. Output ONLY WGSL.'; files = @("$repo\crates\ember-engine\src\shader.wgsl");
       prompt = 'Draft an upgraded version of this WGSL scene shader: keep the exact vertex inputs/outputs and bind groups, improve the fragment shader to Blinn-Phong (sun + fill light + rim), add distance fog fading to a dark horizon color, keep the texture*color albedo path. Comment the tuning constants.' },
    @{ name = 'overlay-plan.md'; worker = 'specht:8087'; max = 4000; sys = 'Senior engine programmer. Output ONLY markdown.'; files = @("$repo\docs\atw-first-rendering.md");
       prompt = 'Write an implementation plan for the egui debug overlay required by section 6 of this ATW doc: crate versions to pin against wgpu 24/25-era APIs, presenter-pass composition (never the SceneFrame), the scene-Hz throttle slider mechanics, and the frame-timing/latency readout data flow. Concrete file-by-file steps for the ember engine.' },
    @{ name = 'review-pong-core.md'; worker = 'specht:8086'; max = 5000; sys = 'Thorough code reviewer. Output ONLY markdown findings: file:line, severity, issue, suggested fix.'; files = @("$repo\crates\pong-core\src\sim.rs", "$repo\crates\pong-core\src\shooter.rs");
       prompt = 'Review these deterministic simulation files for correctness bugs, determinism hazards (NaN, float accumulation, iteration-order dependence), and protocol edge cases. Only report real issues you can point to.' },
    @{ name = 'props-plan.md'; worker = 'specht:8087'; max = 3500; sys = 'Senior game programmer. Output ONLY markdown.'; files = @("$repo\crates\game\src\main.rs");
       prompt = 'Write a step-by-step plan to add static props (crates, barrels, pillars, barricades) to this arena client: mesh registration strategy reusing box_mesh/plane_mesh, a props table loaded from assets/layouts/*.json, rendering instances, and (later) matching server-side collision. Note exact functions to touch.' }
)

foreach ($t in $tasks) {
    $args = @{ SshWorker = $t.worker; Label = "idle:$($t.name)"; System = $t.sys; Prompt = $t.prompt; MaxTokens = $t.max; TimeoutSec = 600 }
    if ($t.files.Count -gt 0) { $args.File = $t.files }
    Write-Output "[queue] $($t.name) -> $($t.worker)"
    try {
        & C:\llama.cpp\glm.ps1 @args > (Join-Path $out $t.name)
        Write-Output "[done] $($t.name) ($((Get-Item (Join-Path $out $t.name)).Length) bytes)"
    } catch { Write-Output "[fail] $($t.name): $($_.Exception.Message)" }
}
Write-Output 'WORKER-QUEUE-COMPLETE'
