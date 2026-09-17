local Config = {}

-- Start here when customizing the template. These values keep the current
-- gameplay feel by default; change them deliberately and test in Studio.
Config.World = {
	Size = Vector2.new(7000, 7000), -- was 4500; bigger arena, more room to run
	SpawnPadding = 220,
}

Config.DynamicWorld = {
	BasePlayers = 6,
	MaxScale = 1.75,
	ClusterPadding = 1050,
	ActiveCellMargin = 260,
	ShrinkDelaySeconds = 35,
	TargetHysteresis = 0.08,
	ExpandSpeed = 750,
	ShrinkSpeed = 120,
	SnapshotResizeStep = 180,
}

Config.Debug = {
	WorldResizeEnabled = false,
	WorldResizeTesterUserIds = {},
}

Config.UI = {
	ForcedScreenOrientation = Enum.ScreenOrientation.LandscapeRight,
}

Config.Persistence = {
	PlayerInfoDataStoreName = "PlayerInfo",
}

Config.Simulation = {
	Hz = 30,
	NetworkHz = 15,
	StaticNetworkHz = 2,
	StaticOverlapHz = 10,
	MaxFrameSteps = 4,
	SpatialCellSize = 160,
}

Config.Player = {
	MaxCells = 32,
	SpawnMass = 1000,
	InitialMass = 1000,
	MinDecayMass = 140,
	DecayPerSecond = 0.0004, -- was 0.001; slower shrink so mass sticks around
	BaseSpeed = 275,
	MinSpeed = 75,
	SpeedExponent = 0.42,
	SpawnInvulnSeconds = 1.2,
	MovementDeadZone = 10,
	MovementDeadZoneRadiusScale = 0.35,
	MovementSlowDistance = 90,
	MovementSlowRadiusScale = 1.2,
	SpawnerBiasChance = 0.85,
	SpawnerBiasMinDistance = 240,
	SpawnerBiasMaxDistance = 760,
	SpawnerBiasAttempts = 12,
}

Config.Cell = {
	-- World-space radius. The old 0.632 scale made the displayed score
	-- substantially larger than the blob looked.
	RadiusScale = 0.78,
	MinEatRatio = 1.25,
	-- A target must be fully covered instead of disappearing on a shallow
	-- overlap. This is used for cells, viruses, and burst objects.
	EatOverlap = 1,
	RecombineSeconds = 12, -- legacy fallback; see RecombineMin/Max below
	-- Mass-scaled recombine: small cells merge back quickly, big cells wait.
	-- Formula: clamp(Min + (mass / ScaleMass) * PerScaleMass, Min, Max).
	RecombineMinSeconds = 1.5, -- floor for very small cells
	RecombineMaxSeconds = 5, -- cap; even the biggest cells wait at most this long
	RecombineScaleMass = 10000,
	RecombinePerScaleMass = 2, -- seconds added per ScaleMass of mass
	SplitMinMass = 100,
	SplitImpulse = 600,
	SplitImpulseMassExponent = 0.28,
	MinSplitImpulseScale = 0.34, -- was 0.24; big-cell splits get real spread too
	SplitInheritedBoostScale = 0.65,
	SplitMaxBoost = 1050,
	SplitBoostDragPerSecond = 2.4,
	MaxSplitPiecesPerCommand = 16,
	-- Spawn close to the parent and let boost create the launch. Spawning two
	-- radii ahead caused authoritative collision before the visual got there.
	SplitSpawnOffsetRadiusScale = 0.35,
	-- Frozen splits stay motionless after spawning, but appear a small
	-- distance toward the cursor so the split still has direction.
	FrozenSplitNudgeRadiusScale = 0.55,
	FrozenSplitHeldBoostScale = 1,
	SplitConsumeGraceSeconds = 0.18,
	SplitPushGraceSeconds = 0.28,
	SplitPushMaxOverlapPerStep = 6,
	-- Client interpolation trails boosted cells slightly. Swept eating could
	-- therefore consume something the local blob had never visually reached.
	SweptEatingEnabled = false,
	SweptEatingMinBoostSpeed = 80,
	SweptEatingMinDistance = 6,
	SweptEatingMaxDistance = 160,
	SamePlayerPushPasses = 1, -- was 2; single pass = smoother same-player resolution
	LoadSamePlayerPushPasses = 1,

	-- ==================================================================
	-- E repeats the normal Space split for every eligible cell twice.
	-- R repeats it three times.
	-- Set enabled = false to disable a hotkey without unbinding it.
	-- ==================================================================
	DoubleSplitEnabled = true,
	TripleSplitEnabled = true,
	RSplitGenerations = 3,
	ESplitGenerations = 2,

	-- Cluster cohesion: keeps a scattered stack of cells grouped up.
	-- ClusterMaxSpeedRatio caps small cells' speed at (biggest cell's
	-- speed * ratio) so they can't sprint away from the pack.
	-- CohesionStrength (0..1) adds a gentle pull toward the group's
	-- center of mass when a cell drifts far from it. 0 disables.
	-- CohesionStrength is now 0: the constant tug toward the centroid
	-- was reading as "snappy / pulling together", especially the
	-- instant you froze. Cluster speed cap alone keeps the pack tight
	-- without any active pulling force.
	-- Ratio raised from 1.15 to 1.6 so small cells can catch up to
	-- the big cell instead of feeling "roped" behind it.
	ClusterMaxSpeedRatio = 1.6,
	CohesionStrength = 0,

	-- Splits aim directly from each source cell at the cursor.
	SplitGroupFanRadians = 0,
	MultiSplitFanRadians = 0,
	MultiSplitStaggerRadiusScale = 0.18,

	-- ==================================================================
	-- CANNIBALIZE (AUTOMATIC): a bigger own-cell will automatically
	-- engulf a smaller sibling cell BEFORE the normal recombine timer
	-- elapses when the bigger cell physically rolls over the smaller
	-- one. No keybind required.
	--
	-- Tuning goal: cannibalize must NOT replace the normal merge
	-- system. The mass-scaled recombine window is ~1.7s (small) to
	-- ~5s (max mass), so cannibalize is deliberately tuned to require
	-- a bigger size gap AND to activate past the top of that window,
	-- so similar-sized siblings always merge instead of being eaten.
	--
	-- Guards:
	--   * Target must be at least CannibalizeSecondsSinceSplit old
	--     (5s — matches the recombine cap so normal merges fire first).
	--   * Eater must be CannibalizeMassRatio× (4x) the target's mass —
	--     equal-sized siblings never eat each other; only clearly
	--     dominant cells cannibalize scraps.
	--   * Target's CENTER must be inside eater's disc (minus
	--     CannibalizeOverlap * targetRadius) — grazing contact is
	--     NOT enough, you must actually cover it.
	-- Set CannibalizeEnabled = false to turn the mechanic off entirely.
	-- ==================================================================
	CannibalizeEnabled = true,
	CannibalizeSecondsSinceSplit = 5.0, -- was 2.0; wait past recombine window
	CannibalizeMassRatio = 4.0,         -- was 2.0; require a real size gap
	CannibalizeOverlap = 0.85,
}

Config.Food = {
	-- Counts scaled up ~2.4x with the world (7000² / 4500²) so pellet
	-- density stays about the same on the larger map.
	TargetCount = 580, -- was 240
	LoadTargetCount = 430, -- was 180
	HeavyLoadTargetCount = 240, -- was 100
	BonusTargetCount = 190, -- was 80
	LoadBonusTargetCount = 120, -- was 50
	HeavyLoadBonusTargetCount = 70, -- was 30
	Mass = 25,
	Radius = 6,
	SpawnBatch = 120,
	PruneBatch = 120,
	SpawnSectionsX = 5,
	SpawnSectionsY = 5,
	Colors = {
		Color3.fromRGB(255, 51, 51),
		Color3.fromRGB(255, 112, 51),
		Color3.fromRGB(255, 170, 51),
		Color3.fromRGB(255, 255, 51),
		Color3.fromRGB(185, 255, 51),
		Color3.fromRGB(102, 255, 51),
		Color3.fromRGB(51, 255, 51),
		Color3.fromRGB(51, 255, 130),
		Color3.fromRGB(51, 255, 210),
		Color3.fromRGB(51, 255, 255),
		Color3.fromRGB(51, 180, 255),
		Color3.fromRGB(51, 105, 255),
		Color3.fromRGB(51, 51, 255),
		Color3.fromRGB(115, 51, 255),
		Color3.fromRGB(180, 51, 255),
		Color3.fromRGB(255, 51, 255),
		Color3.fromRGB(255, 51, 170),
		Color3.fromRGB(255, 51, 105),
	},
}

Config.Virus = {
	-- Keep enough hazards in the enlarged world that several are normally
	-- visible around a player instead of being lost between camera regions.
	TargetCount = 120,
	Mass = 300,
	Radius = 14,
	EatSplitMinMass = 2000,
	EatOverlap = 0.5,
	-- Below the 32-cell cap a virus bursts the eater into more pieces.
	-- At the cap, the virus is absorbed and its mass is gained instead.
	SplitOnEat = true,
	MaxBurstPieces = 8,
	BumpVelocityTransfer = 0.7,
	BumpMinSpeed = 140,
	BumpMaxSpeed = 300,
	BumpNudge = 5,
	DragPerSecond = 1.8,
	WallBounceScale = 0.25,
	StopSpeed = 10,
	DynamicSnapshotMinSpeed = 8,
	SpawnSectionsX = 4,
	SpawnSectionsY = 3,
}

Config.Spawner = {
	TargetCount = 6, -- was 3; scaled with bigger map
	BaseMass = 900,
	BaseRadius = 82,
	MaxRadius = 1600,
	EatCellRadiusRatio = 1.25,
	BurstMinMass = 2000,
	-- Every released pellet has this fixed mass. PelletMass = 0 used the
	-- adaptive ambient-food value and made rewards vary with server load.
	PelletMass = 25,
	PelletMassFraction = 0.45,
	GrowthMassFraction = 0.35,
	GrowthPerSecond = 900,
	DecayPerSecond = 0.12,
	MaxPelletsPerFeed = 64,
	MaxMapPellets = 360,
	PelletScatterRadius = 110,
}

Config.Barrier = {
	TargetCount = 0,
	Size = Vector2.new(200, 200),
	Friction = 7,
	PushTransfer = 0.32,
}

Config.Coin = {
	TargetCount = 45,
	Value = 1,
	Radius = 10,
	SpawnBatch = 30,
}

Config.Progression = {
	MaxLevel = 100,
	LifeXpCap = 25000,
	XpRate = 0.6,
	MassExponent = 0.5,
	BaseStartMass = 1000,
	MaxStartMass = 1000,
	StartMassCurveExponent = 1.6,
	DefaultXpBoostMultiplier = 1,
	LegacyCoinScaleDivisor = 10,
	EconomyVersion = 2,
}

Config.Shop = {
	NicknameMaxLength = 20,
}

-- ==================================================================
-- FREEZE: press F to TOGGLE freeze on your own cells. Press F once
-- to hard-stop every one of your cells in place; press F again to
-- release. Cells preserve their split-boost momentum while frozen
-- (velocity is paused, not zeroed), so a mid-flight split resumes
-- its trajectory when you unfreeze. Merging still happens normally
-- while frozen (touching cells past their recombine timer merge).
-- Debounce prevents accidental double-taps from cancelling.
-- ==================================================================
Config.Freeze = {
	Enabled = true,
	Debounce = 0.3, -- was 0.15; longer window kills F-spam scatter
	Cost = 0,
	-- Overlapping frozen cells are separated gradually after release.
	-- Their boost is cleared by the server; there is no radial release fan.
	UnfreezeGraceSeconds = 2.5,
	UnfreezeGraceStrength = 0.03,
	UnfreezeGraceCurveExponent = 2.2,
	UnfreezeMaxOverlapPerPass = 2,
	UnfreezePushPasses = 1,
}

Config.Input = {
	TouchButtonImages = {
		Shoot = {
			Up = "rbxassetid://138709858109425",
			Down = "rbxassetid://120562342792348",
		},
		Split = {
			Up = "rbxassetid://113043524762022",
			Down = "rbxassetid://88597800137043",
		},
	},
	TouchButtonPositions = {
		Shoot = UDim2.new(0.805, 0, 0.738, 0),
		Split = UDim2.new(0.863, 0, 0.513, 0),
	},
}

Config.Ejected = {
	-- Feeding always transfers this fixed amount; it is not derived from the
	-- firing player's largest cell.
	Mass = 10,
	PickupMassMultiplier = 1,
	Radius = 4,
	NozzleOffset = 2,
	Cost = 0,
	FrozenCost = 10,
	MinFireMass = 0,
	EatMinCellMass = 1,
	TouchPickupPadding = 0,
	PickupCoverage = 1, -- 1 = the whole pellet must be inside the receiving cell
	-- Self-feed recovery was scaling gain down based on TOTAL player mass:
	-- at high mass, feeding a small sibling gave ~5% of the pellet's mass,
	-- so small pieces disappeared visually without actually growing. Set
	-- MinScale = 1 so the receiving cell always gets the full transfer.
	SelfRecoveryStartScore = 400000,
	SelfRecoveryEndScore = 2400000,
	SelfRecoveryMinScale = 1, -- was 0.05; small pieces couldn't grow when total mass was high
	SelfRecoveryCurveExponent = 0.7,
	Speed = 410,
	DragPerSecond = 1.15,
	WallBounceScale = 0.22,
	CollisionEnabled = false,
	CollisionMinSpeed = 28,
	CollisionRadiusScale = 1.15,
	CollisionStrength = 0.58,
	CollisionVelocityTransfer = 0.32,
	CollisionMaxPush = 16,
	CollisionMaxImpactsPerMass = 8,
	LoadCollisionMaxImpactsPerMass = 5,
	HeavyLoadCollisionMaxImpactsPerMass = 0,
	LifeSeconds = 30, -- was 10; ejected pellets stick around longer
	LoadLifeSeconds = 22, -- was 8
	HeavyLoadLifeSeconds = 16, -- was 7
	OwnerReeatDelay = 0.1,
	LocalVisualMaxCellsPerShotTick = 32,
	LocalVisualLifeSeconds = 1.25,
	LocalVisualMinVisibleSeconds = 0.08,
	OwnerTrimRetainRadius = 1800,
	MaxCount = 3000,
	PerPlayerMaxCount = 384,
	LoadPerPlayerMaxCount = 240,
	HeavyLoadPerPlayerMaxCount = 160,
	MaxCellsPerShotTick = 32,
	LoadMaxCellsPerShotTick = 32,
	HeavyLoadMaxCellsPerShotTick = 32,
	FireHz = 17,
	MaxEjectsPerStep = 6,
	ConeDegrees = 0, -- zero spread; pellet flies exactly at cursor
	-- Feeding a small cell inside a cluster: the owned cell nearest
	-- the cursor is excluded from firing so it acts as a pure
	-- receiver. Without this, surrounding big cells eat each other's
	-- pellets before they can reach the tiny target.
	SkipTargetCell = true,
	SelfFeedCenterRadius = 180,
	SelfFeedVisualPellets = 2,
	-- When true, own pellets are LOCKED to the target cell — sibling
	-- own-cells cannot pick them up even if they cross the pellet's
	-- path. Enemies can still eat them normally, and after the pellet
	-- has lived past LockedTargetTimeout seconds the lock releases
	-- (so misses don't produce eternally-uneatable pellets).
	LockPelletsToTarget = true,
	LockedTargetTimeout = 1.25,
}

Config.Network = {
	InputHz = 20,
	ViewportPadding = 220,
	LoadViewportPadding = 160,
	HeavyLoadViewportPadding = 120,
	MaxSnapshotRadius = 4200,
	LoadMaxSnapshotRadius = 3600,
	HeavyLoadMaxSnapshotRadius = 3000,
	StaticRefreshDistance = 220,
	StaticRefreshRadiusDelta = 240,
	StaticRefreshMaxInterval = 2.5,
	MaxCellsPerSnapshot = 220,
	MaxFoodPerSnapshot = 150,
	MaxVirusesPerSnapshot = 32,
	MaxSpawnersPerSnapshot = 8,
	MaxBarriersPerSnapshot = 6,
	MaxEjectedPerSnapshot = 120,
	MaxOwnEjectedPerSnapshot = 80,
	MaxRemoteEjectedPerSnapshot = 40,
	FastMaxCellsPerSnapshot = 96,
	FastMaxRemoteCellsPerSnapshot = 64,
	FastCellSidecarRows = 20,
	FastMaxEjectedPerSnapshot = 88,
	FastMaxOwnEjectedPerSnapshot = 80,
	FastMaxRemoteEjectedPerSnapshot = 8,
	FastEjectedSidecarRows = 24,
	FastMaxSpawnersPerSnapshot = 1,
	FastMaxBarriersPerSnapshot = 6,
	FastSnapshotByteBudget = 820,
	MaxCoinsPerSnapshot = 180,
	AdaptiveStartPlayers = 20,
	HeavyLoadPlayers = 30,
	HeavyLoadStaticHz = 3,
	StaticRefreshBuckets = 4,
	MediumStaticScale = 0.75,
	MediumDynamicScale = 0.8,
	HeavyStaticScale = 0.55,
	HeavyDynamicScale = 0.65,
	PositionPrecision = 0.1,
	MassPrecision = 0.1,
}

Config.Render = {
	WorldToScreenScale = 1,
	MinCirclePixels = 4,
	-- Smoothness knobs. Higher = snappier / more responsive but jittery.
	-- Lower = smoother / floatier. dt-independent (alpha = 1 - exp(-k*dt)).
	InterpolationSharpness = 9, -- was 12; even smoother position/radius lerp
	OwnCellPredictionEnabled = true,
	OwnCellPredictionReconcileSharpness = 3.5, -- was 5; gentler reconciliation with server
	-- Frozen reconcile: when localFrozen is true, use THIS sharpness
	-- instead of the value above. Very low = displayPos drifts to the
	-- true server position over ~1s instead of snapping the moment
	-- freeze triggers, killing the "cells pull inward on freeze" feel.
	FrozenReconcileSharpness = 1.2,
	OwnCellPredictionReconcileDeadband = 46,
	OwnCellPredictionReconcileDeadbandRadiusScale = 0.65,
	OwnCellPredictionSnapDistance = 650,
	OwnCellPredictionCameraWeight = 1,
	OwnCellPredictionMaxLeadSeconds = 0.22,
	OwnCellPredictionLeadExtraSeconds = 0.025,
	OwnCellPredictionLeadScale = 1,
	OwnCellVisualSeparationSeconds = 12,
	OwnCellVisualSeparationPasses = 2, -- restored to 2 for firm separation on normal splits
	OwnCellVisualSeparationStrength = 0.75, -- was 0.55; firmer per-frame push
	OwnCellVisualSeparationScale = 1.02,
	OwnBarrierPredictionPasses = 2,
	MobileJoystickSmoothingSharpness = 32,
	FoodZIndex = 3,
	EjectedZIndex = 4,
	ObjectMinZIndex = 6,
	CellMinZIndex = 7,
	HudRefreshHz = 8,
	CameraSharpness = 7, -- was 10; softer camera follow
	MinZoom = 0.09,
	MaxZoom = 4,
	ManualZoomMin = 0.28,
	ManualZoomMax = 3,
	AgarZoomReferenceSize = 160,
	AgarZoomExponent = 0.4,
	AgarZoomReferenceWidth = 1920,
	AgarZoomReferenceHeight = 1080,
	AgarZoomOutScale = 0.72,
	AgarZoomBlendPer60Hz = 0.1,
	ExtrapolationSeconds = 0.08,
	StaticConfirmSnapshots = 3,
	StaleGraceSnapshots = 2,
	DynamicMissingGraceSnapshots = 2,
	RemoteCellMissingGraceSnapshots = 12,
	EjectedMissingGraceSnapshots = 8,
	StaticMissingGraceSnapshots = 10,
	StaticMissingGraceSeconds = 5,
	-- The visual-only all-pairs pellet solver was the main W-hold FPS spike.
	-- Server movement/collision remains authoritative.
	EjectedVisualCollisionEnabled = false,
	EjectedVisualCollisionMaxStates = 160,
	EjectedVisualCollisionPasses = 3,
	EjectedVisualCollisionScale = 1.08,
	EjectedVisualCollisionStrength = 0.9,
	EjectedVisualCollisionSharpness = 20,
	EjectedVisualCollisionMaxPush = 22,
	EjectedVisualCollisionMaxOffset = 42,
	SplitSpawnAnimationEnabled = true, -- smooth split arc instead of instant snap
	-- The launch follows its authoritative target immediately; smoothstep
	-- controls the visual offset and radius growth without holding the child
	-- on its parent.
	SplitSpawnAnimationSeconds = 0.38,
	SplitSpawnAnimationStartRadiusScale = 0.72,
	SplitSpawnAnimationEndDistance = 1,
	SplitSpawnAnimationSharpness = 24,
	SplitSpawnAnimationTargetSharpness = 20,
	SplitSpawnAnimationTargetLeadSeconds = 0.14,
	SplitSpawnAnimationMaxOverrunSeconds = 0.08,
	SplitSpawnAnimationMaxDistance = 900,
	SplitSpawnAnimationRadiusScale = 4.5,
	ConsumeAnimationSeconds = 0.22,
	ConsumeAnimationSharpness = 18,
	MergeAnimationSeconds = 0.42,
	StaticCachePaddingPixels = 140,
	StaticPositionTolerance = 2,
	FoodColor = Color3.fromRGB(90, 220, 120),
	VirusColor = Color3.fromRGB(82, 196, 26),
	VirusImage = "",
	SpawnerColor = Color3.fromRGB(255, 172, 76),
	SpawnerImage = "rbxassetid://86574435486520",
	BarrierColor = Color3.fromRGB(96, 108, 124),
	BarrierImage = "rbxassetid://101642117455922",
	CoinColor = Color3.fromRGB(255, 196, 56),
	CoinImage = "rbxassetid://6751051684",
	EjectedColor = Color3.fromRGB(245, 230, 115),
	BackgroundColor = Color3.fromRGB(247, 247, 247),
	GridColor = Color3.fromRGB(218, 225, 235),
}

-- ==================================================================
-- LIVE CONFIG MENU (admin only)
-- Press ] (RightBracket) in-game to open the tunable menu. Only
-- players in Config.Admin.UserIds — or the place creator — can push
-- changes. Every change fires the Agar2DRemotes.ConfigUpdate
-- RemoteEvent; the server validates + clamps against the schema
-- below, mutates this Config table, then broadcasts to all clients
-- so both gameplay and rendering stay in sync.
--
-- Add your UserId(s) to Config.Admin.UserIds when the place is
-- group-owned or you want teammates to have access too.
-- ==================================================================
Config.Admin = {
	UserIds = {}, -- e.g. {12345678, 87654321}
}

Config.Tunables = {
	-- Cell
	{ path = "Cell.SplitImpulse",                label = "Split Impulse",             type = "number", min = 100,  max = 3000,  step = 25 },
	{ path = "Cell.SplitMinMass",                label = "Split Min Mass",            type = "number", min = 100,  max = 20000, step = 100, int = true },
	{ path = "Cell.RecombineMinSeconds",         label = "Merge Cooldown Min (s)",    type = "number", min = 0.1,  max = 15,    step = 0.1 },
	{ path = "Cell.RecombineMaxSeconds",         label = "Merge Cooldown Max (s)",    type = "number", min = 0.5,  max = 60,    step = 0.5 },
	{ path = "Cell.RecombinePerScaleMass",       label = "Merge sec / ScaleMass",     type = "number", min = 0,    max = 30,    step = 0.1 },
	{ path = "Cell.MultiSplitFanRadians",        label = "Multi-Split Fan (rad)",     type = "number", min = 0,    max = 1.5,   step = 0.01 },
	{ path = "Cell.ClusterMaxSpeedRatio",        label = "Cluster Max Speed Ratio",   type = "number", min = 1.0,  max = 3,     step = 0.05 },
	{ path = "Cell.CohesionStrength",            label = "Cohesion Strength",         type = "number", min = 0,    max = 1,     step = 0.01 },
	{ path = "Cell.MinEatRatio",                 label = "Min Eat Ratio",             type = "number", min = 1,    max = 3,     step = 0.05 },
	{ path = "Cell.DoubleSplitEnabled",          label = "R Four-Cell Split Enabled", type = "bool" },
	{ path = "Cell.TripleSplitEnabled",          label = "E Three-Cell Split Enabled", type = "bool" },

	-- Player
	{ path = "Player.MaxCells",                  label = "Max Cells",                 type = "number", min = 1,    max = 64,    step = 1, int = true },
	{ path = "Player.BaseSpeed",                 label = "Base Speed",                type = "number", min = 50,   max = 1200,  step = 5 },
	{ path = "Player.MinSpeed",                  label = "Min Speed",                 type = "number", min = 10,   max = 500,   step = 5 },
	{ path = "Player.SpeedExponent",             label = "Speed Exponent",            type = "number", min = 0,    max = 2,     step = 0.01 },
	{ path = "Player.DecayPerSecond",            label = "Decay / Second",            type = "number", min = 0,    max = 0.02,  step = 0.0001 },
	{ path = "Player.SpawnInvulnSeconds",        label = "Spawn Invuln (s)",          type = "number", min = 0,    max = 10,    step = 0.1 },

	-- Food
	{ path = "Food.Mass",                        label = "Food Mass",                 type = "number", min = 1,    max = 500,   step = 1 },

	-- Ejected (feed)
	{ path = "Ejected.Mass",                     label = "Feed Pellet Mass",          type = "number", min = 10,   max = 1000,  step = 5 },
	{ path = "Ejected.FireHz",                   label = "Feed Fire Rate (pellets/s)", type = "number", min = 1,    max = 30,    step = 1 },
	{ path = "Ejected.Speed",                    label = "Feed Pellet Speed",         type = "number", min = 100,  max = 1500,  step = 10 },
	{ path = "Ejected.DragPerSecond",            label = "Feed Pellet Drag / s",      type = "number", min = 0,    max = 10,    step = 0.1 },
	{ path = "Ejected.LifeSeconds",              label = "Feed Pellet Life (s)",      type = "number", min = 1,    max = 60,    step = 0.5 },
	{ path = "Ejected.SelfRecoveryMinScale",     label = "Self-Feed Min Scale",       type = "number", min = 0,    max = 1,     step = 0.01 },
	{ path = "Ejected.OwnerReeatDelay",          label = "Owner Re-Eat Delay (s)",    type = "number", min = 0,    max = 5,     step = 0.05 },
	{ path = "Ejected.TouchPickupPadding",       label = "Pickup Overlap (px)",       type = "number", min = -40,  max = 40,    step = 1 },
	{ path = "Ejected.Cost",                     label = "Feed Fire Cost (mass)",     type = "number", min = 0,    max = 500,   step = 5 },
	{ path = "Ejected.LockPelletsToTarget",      label = "Lock Pellets to Target",    type = "bool" },
	{ path = "Ejected.LockedTargetTimeout",      label = "Pellet Lock Timeout (s)",   type = "number", min = 0,    max = 10,    step = 0.1 },

	-- Virus
	{ path = "Virus.Mass",                       label = "Virus Mass",                type = "number", min = 100,  max = 5000,  step = 25 },
	{ path = "Virus.SplitOnEat",                 label = "Virus Splits on Eat",       type = "bool" },

	-- Freeze
	{ path = "Freeze.Enabled",                   label = "Freeze Enabled",            type = "bool" },
	{ path = "Freeze.UnfreezeGraceSeconds",      label = "Unfreeze Grace (s)",        type = "number", min = 0,    max = 15,    step = 0.1 },
	{ path = "Freeze.UnfreezeGraceStrength",     label = "Unfreeze Grace Strength",   type = "number", min = 0,    max = 1,     step = 0.01 },
	{ path = "Freeze.UnfreezeMaxOverlapPerPass", label = "Unfreeze Max Overlap/Pass", type = "number", min = 0,    max = 30,    step = 0.1 },
	{ path = "Freeze.ReleaseImpulse",             label = "Unfreeze Release Impulse",  type = "number", min = 0,    max = 3000,  step = 20 },
	{ path = "Freeze.ReleaseImpulseMinScale",     label = "Release Impulse Min Scale", type = "number", min = 0,    max = 1,     step = 0.05 },
	{ path = "Freeze.ReleaseMinHoldSeconds",      label = "Release Min Hold (s)",      type = "number", min = 0,    max = 5,     step = 0.05 },

	-- Cannibalize (hold C)
	{ path = "Cell.CannibalizeEnabled",           label = "Cannibalize Enabled",       type = "bool" },
	{ path = "Cell.CannibalizeSecondsSinceSplit", label = "Cannibalize Age (s)",       type = "number", min = 0,    max = 30,    step = 0.1 },
	{ path = "Cell.CannibalizeMassRatio",         label = "Cannibalize Mass Ratio",    type = "number", min = 1,    max = 10,    step = 0.1 },
	{ path = "Cell.CannibalizeOverlap",           label = "Cannibalize Overlap",       type = "number", min = 0,    max = 1,     step = 0.05 },
}

return Config
