--!strict
--[[
    AUTONOMOUS COMBAT COMPANION
    Roblox Studio / Server Script
    Architecture: State Machine + Navigation + Threat Analysis

    Required NPC components:
        Model
        Humanoid
        HumanoidRootPart

    Optional NPC components:
        Animator inside Humanoid
        Tools inside the NPC model
]]

local function StartCompanion()
    ------------------------------------------------------------
    -- SERVICES
    ------------------------------------------------------------

    local Players = game:GetService("Players")
    local RunService = game:GetService("RunService")
    local Workspace = game:GetService("Workspace")
    local CollectionService = game:GetService("CollectionService")

    ------------------------------------------------------------
    -- NPC REFERENCES
    ------------------------------------------------------------

    local NPC = script.Parent

    assert(NPC:IsA("Model"),
        "Companion script must be inside a Model.")

    local Humanoid = NPC:WaitForChild("Humanoid")
        :: Humanoid

    local Root = NPC:WaitForChild("HumanoidRootPart")
        :: BasePart

    local Animator =
        Humanoid:FindFirstChildOfClass("Animator")

    ------------------------------------------------------------
    -- MODULE 1: GLOBAL STATE DEFINITION & MONITORING
    ------------------------------------------------------------

    local Config = {
        Movement = {
            WalkSpeed = 28,
            KineticVelocity = 35,

            ChaseDistance = 4,
            MaximumEngagementDistance = 150,

            MoveToRefreshInterval = 0.15,
            DirectionalImpulseCooldown = 0.25,

            JumpEnabled = true,
            JumpCooldown = 0.8,

            AntiStuckDuration = 2.0,
            AntiStuckMinimumProgress = 1.25,
            RecoveryCooldown = 1.5,

            RaycastLength = 5,
            RaycastHeightOffset = 1.5,
            RaycastSideOffset = 1.5,
            RaycastGroundLength = 8,

            MinimumMoveDirection = 0.05,
        },

        Targeting = {
            ScanInterval = 0.12,
            MaximumDistance = 150,
            RequireLineOfSight = false,
            IgnoreForceFieldTargets = true,
            IgnoreNPCs = true,
        },

        Threat = {
            UpdateInterval = 1 / 30,
            VelocityThreshold = 32,

            AnimationKeywords = {
                "atk",
                "hit",
                "swing",
                "punch",
                "kick",
                "skill",
                "execute",
            },

            ThreatHoldDuration = 0.35,
            BlockCooldown = 0.15,
            MaximumTrackNameLength = 128,
        },

        Combat = {
            AttackDistance = 4,

            ComboCooldown = 0.8,
            ToolActivationCount = 3,
            ToolActivationInterval = 0.12,

            SkillNames = {
                "1",
                "2",
                "3",
                "4",
                "Awaken",
                "g",
            },

            SkillCooldown = 1.5,
        },

        Debug = {
            Enabled = true,
            HighlightTargets = true,
            HighlightColor = Color3.fromRGB(255, 75, 75),
            HighlightTransparency = 0.65,
            RefreshInterval = 0.75,
        },
    }

    local States = {
        Idling = "Idling",
        Chasing = "Chasing",
        Parrying = "Parrying",
        Attacking = "Attacking",
        Recovering = "Recovering",
        Disabled = "Disabled",
    }

    local CurrentState = States.Idling

    local CurrentTarget: Model? = nil
    local TargetHumanoid: Humanoid? = nil
    local TargetRoot: BasePart? = nil

    local IsRunning = true
    local IsBlocking = false
    local IsRecovering = false

    local LastTargetScan = 0
    local LastNavigationUpdate = 0
    local LastImpulse = 0
    local LastJump = 0
    local LastRecovery = 0
    local LastCombo = 0
    local LastSkillActivation = 0
    local LastBlockUpdate = 0
    local LastProgressTime = os.clock()

    local LastProgressPosition = Root.Position

    local ThreatExpiresAt = 0
    local LastKnownTargetPosition: Vector3? = nil

    local LastActionId = 0

    local Connections: { RBXScriptConnection } = {}
    local Highlights: { [Model]: Highlight } = {}

    local OriginalCanCollide: { [BasePart]: boolean } = {}

    local OriginalWalkSpeed = Humanoid.WalkSpeed
    local OriginalAutoRotate = Humanoid.AutoRotate

    local CombatAction = Instance.new("BindableEvent")
    CombatAction.Name = "CombatAction"
    CombatAction.Parent = NPC

    local CleanupEvent = Instance.new("BindableEvent")
    CleanupEvent.Name = "CompanionCleanup"
    CleanupEvent.Parent = NPC

    local DebugFolder = Instance.new("Folder")
    DebugFolder.Name = "CompanionDebugAssets"
    DebugFolder.Parent = NPC

    ------------------------------------------------------------
    -- CONNECTION MANAGEMENT
    ------------------------------------------------------------

    local function TrackConnection(
        connection: RBXScriptConnection
    )
        table.insert(Connections, connection)
        return connection
    end

    local function SafeCall(callback: () -> ())
        local success, errorMessage = xpcall(
            callback,
            debug.traceback
        )

        if not success then
            warn(
                "[CombatCompanion] Protected operation failed:\n",
                errorMessage
            )
        end
    end

    local function SetState(newState: string)
        if not IsRunning then
            return
        end

        if CurrentState == newState then
            return
        end

        CurrentState = newState
        NPC:SetAttribute("CompanionState", newState)

        SafeCall(function()
            CombatAction:Fire("StateChanged", {
                State = newState,
                Target = CurrentTarget,
                Timestamp = os.clock(),
            })
        end)
    end

    ------------------------------------------------------------
    -- CHARACTER VALIDATION
    ------------------------------------------------------------

    local function IsLivingCharacter(
        character: Model?
    ): boolean
        if not character or not character.Parent then
            return false
        end

        local humanoid =
            character:FindFirstChildOfClass("Humanoid")

        local root =
            character:FindFirstChild("HumanoidRootPart")

        if not humanoid or not root
            or not root:IsA("BasePart")
        then
            return false
        end

        if humanoid.Health <= 0 then
            return false
        end

        if humanoid:GetState()
            == Enum.HumanoidStateType.Dead
        then
            return false
        end

        return true
    end

    local function HasForceField(
        character: Model
    ): boolean
        for _, descendant in ipairs(
            character:GetChildren()
        ) do
            if descendant:IsA("ForceField") then
                return true
            end
        end

        return false
    end

    local function GetCharacterRoot(
        character: Model?
    ): BasePart?
        if not character then
            return nil
        end

        local root =
            character:FindFirstChild("HumanoidRootPart")

        if root and root:IsA("BasePart") then
            return root
        end

        return nil
    end

    ------------------------------------------------------------
    -- NETWORK OWNERSHIP
    ------------------------------------------------------------

    SafeCall(function()
        Root:SetNetworkOwner(nil)
    end)

    Humanoid.WalkSpeed = Config.Movement.WalkSpeed

    NPC:SetAttribute("CompanionState", CurrentState)
    NPC:SetAttribute("CompanionBlocking", false)
    NPC:SetAttribute("CompanionTarget", "")
    NPC:SetAttribute("CompanionThreat", false)

    ------------------------------------------------------------
    -- MODULE 2: ADVANCED SENSORY GRAPHICS / ESP
    ------------------------------------------------------------

    local function RemoveHighlight(character: Model)
        local highlight = Highlights[character]

        if highlight then
            SafeCall(function()
                highlight:Destroy()
            end)

            Highlights[character] = nil
        end
    end

    local function CreateOrUpdateHighlight(
        character: Model
    )
        if not Config.Debug.Enabled
            or not Config.Debug.HighlightTargets
        then
            return
        end

        if character == NPC then
            return
        end

        if not character.Parent then
            RemoveHighlight(character)
            return
        end

        if not character:FindFirstChildOfClass("Humanoid") then
            RemoveHighlight(character)
            return
        end

        local highlight = Highlights[character]

        if not highlight or not highlight.Parent then
            highlight = Instance.new("Highlight")

            highlight.Name = "CompanionTargetHighlight"
            highlight.Adornee = character

            highlight.DepthMode =
                Enum.HighlightDepthMode.Occluded

            highlight.FillColor =
                Config.Debug.HighlightColor

            highlight.OutlineColor = Color3.new(1, 1, 1)

            highlight.FillTransparency =
                Config.Debug.HighlightTransparency

            highlight.OutlineTransparency = 0.1
            highlight.Enabled = true
            highlight.Parent = DebugFolder

            Highlights[character] = highlight
        end

        local isTarget = character == CurrentTarget

        highlight.OutlineColor = if isTarget
            then Color3.fromRGB(255, 220, 50)
            else Color3.new(1, 1, 1)
    end

    local function RefreshHighlights()
        if not Config.Debug.Enabled then
            return
        end

        local seen: { [Model]: boolean } = {}

        for _, descendant in ipairs(
            Workspace:GetDescendants()
        ) do
            if descendant:IsA("Humanoid") then
                local character = descendant.Parent

                if character
                    and character:IsA("Model")
                    and character ~= NPC
                then
                    seen[character] = true

                    SafeCall(function()
                        CreateOrUpdateHighlight(character)
                    end)
                end
            end
        end

        for character in pairs(Highlights) do
            if not seen[character]
                or not character.Parent
            then
                RemoveHighlight(character)
            end
        end
    end

    ------------------------------------------------------------
    -- MODULE 3: RAYCAST NAVIGATOR
    ------------------------------------------------------------

    local RaycastParamsObject = RaycastParams.new()

    RaycastParamsObject.FilterType =
        Enum.RaycastFilterType.Exclude

    RaycastParamsObject.FilterDescendantsInstances = {
        NPC,
        DebugFolder,
    }

    RaycastParamsObject.IgnoreWater = true

    local function RaycastDirection(
        origin: Vector3,
        direction: Vector3
    ): RaycastResult?
        local success, result = pcall(function()
            return Workspace:Raycast(
                origin,
                direction,
                RaycastParamsObject
            )
        end)

        if not success then
            return nil
        end

        return result
    end

    local function IsObstacle(
        result: RaycastResult?
    ): boolean
        if not result then
            return false
        end

        local part = result.Instance

        if not part:IsA("BasePart") then
            return true
        end

        if not part.CanCollide then
            return false
        end

        return true
    end

    local function RestoreCollisionState()
        for part, originalValue in pairs(
            OriginalCanCollide
        ) do
            if part and part.Parent then
                SafeCall(function()
                    part.CanCollide = originalValue
                end)
            end
        end

        table.clear(OriginalCanCollide)
    end

    local function InspectCharacterCollision()
        for _, descendant in ipairs(
            NPC:GetDescendants()
        ) do
            if descendant:IsA("BasePart")
                and OriginalCanCollide[descendant] == nil
            then
                OriginalCanCollide[descendant] =
                    descendant.CanCollide
            end
        end
    end

    local function ScanObstacle(): boolean
        local forward = Root.CFrame.LookVector

        local origin = Root.Position
            + Vector3.new(
                0,
                Config.Movement.RaycastHeightOffset,
                0
            )

        local centerHit = RaycastDirection(
            origin,
            forward * Config.Movement.RaycastLength
        )

        local leftDirection = (
            forward
            - Root.CFrame.RightVector * 0.25
        ).Unit

        local rightDirection = (
            forward
            + Root.CFrame.RightVector * 0.25
        ).Unit

        local leftHit = RaycastDirection(
            origin,
            leftDirection * Config.Movement.RaycastLength
        )

        local rightHit = RaycastDirection(
            origin,
            rightDirection * Config.Movement.RaycastLength
        )

        local blocked = IsObstacle(centerHit)

        if blocked and Config.Movement.JumpEnabled then
            local now = os.clock()

            if now - LastJump
                >= Config.Movement.JumpCooldown
            then
                LastJump = now

                SafeCall(function()
                    Humanoid.Jump = true

                    Humanoid:ChangeState(
                        Enum.HumanoidStateType.Jumping
                    )
                end)
            end
        end

        local leftBlocked = IsObstacle(leftHit)
        local rightBlocked = IsObstacle(rightHit)

        NPC:SetAttribute("ObstacleAhead", blocked)
        NPC:SetAttribute("ObstacleLeft", leftBlocked)
        NPC:SetAttribute("ObstacleRight", rightBlocked)

        return blocked
    end

    local function HasLineOfSight(
        targetRoot: BasePart
    ): boolean
        local origin = Root.Position

        local direction =
            targetRoot.Position - origin

        if direction.Magnitude <= 0.01 then
            return true
        end

        local result = RaycastDirection(
            origin,
            direction
        )

        if not result then
            return true
        end

        return result.Instance:IsDescendantOf(
            targetRoot.Parent :: Instance
        )
    end

    local function RecoverFromStuck()
        local now = os.clock()

        if now - LastRecovery
            < Config.Movement.RecoveryCooldown
        then
            return
        end

        LastRecovery = now
        LastProgressTime = now
        LastProgressPosition = Root.Position

        SetState(States.Recovering)

        SafeCall(function()
            Humanoid:Move(Vector3.zero, false)
            Humanoid.Jump = true
        end)

        SafeCall(function()
            CombatAction:Fire("NavigationRecovery", {
                Position = Root.Position,
                Target = CurrentTarget,
                Timestamp = now,
            })
        end)
    end

    local function UpdateAntiStuck()
        if Humanoid.MoveDirection.Magnitude
            < Config.Movement.MinimumMoveDirection
        then
            LastProgressPosition = Root.Position
            LastProgressTime = os.clock()
            return
        end

        local now = os.clock()

        local displacement = (
            Root.Position - LastProgressPosition
        ).Magnitude

        if displacement
            >= Config.Movement.AntiStuckMinimumProgress
        then
            LastProgressPosition = Root.Position
            LastProgressTime = now
            return
        end

        if now - LastProgressTime
            >= Config.Movement.AntiStuckDuration
        then
            RecoverFromStuck()
        end
    end

    local function UpdateNavigation()
        if not CurrentTarget or not TargetRoot then
            Humanoid:Move(Vector3.zero, false)
            return
        end

        if not IsLivingCharacter(CurrentTarget) then
            return
        end

        local now = os.clock()

        if now - LastNavigationUpdate
            < Config.Movement.MoveToRefreshInterval
        then
            return
        end

        LastNavigationUpdate = now

        local displacement =
            TargetRoot.Position - Root.Position

        local distance = displacement.Magnitude

        if distance <= Config.Movement.ChaseDistance then
            Humanoid:Move(Vector3.zero, false)
            return
        end

        local obstacleAhead = ScanObstacle()

        if obstacleAhead then
            local leftClearance = RaycastDirection(
                Root.Position,
                -Root.CFrame.RightVector
                    * Config.Movement.RaycastSideOffset
            )

            local rightClearance = RaycastDirection(
                Root.Position,
                Root.CFrame.RightVector
                    * Config.Movement.RaycastSideOffset
            )

            local leftIsClear = leftClearance == nil
                or not IsObstacle(leftClearance)

            local rightIsClear = rightClearance == nil
                or not IsObstacle(rightClearance)

            if leftIsClear then
                Humanoid:Move(
                    -Root.CFrame.RightVector,
                    false
                )
            elseif rightIsClear then
                Humanoid:Move(
                    Root.CFrame.RightVector,
                    false
                )
            else
                Humanoid:Move(Vector3.zero, false)
            end

            return
        end

        Humanoid:MoveTo(TargetRoot.Position)

        if now - LastImpulse
            >= Config.Movement.DirectionalImpulseCooldown
        then
            LastImpulse = now

            local horizontal = Vector3.new(
                displacement.X,
                0,
                displacement.Z
            )

            if horizontal.Magnitude > 0.01 then
                local direction = horizontal.Unit

                local currentVelocity =
                    Root.AssemblyLinearVelocity

                local horizontalVelocity = Vector3.new(
                    currentVelocity.X,
                    0,
                    currentVelocity.Z
                )

                if horizontalVelocity.Magnitude
                    < Config.Movement.KineticVelocity
                then
                    local impulse =
                        direction
                        * Config.Movement.KineticVelocity

                    Root:ApplyImpulse(
                        impulse * Root.AssemblyMass * 0.15
                    )
                end
            end
        end
    end

    ------------------------------------------------------------
    -- MODULE 4: AUTOMATED TARGET VALUATION
    ------------------------------------------------------------

    local function IsValidTarget(
        character: Model
    ): boolean
        if character == NPC then
            return false
        end

        if not IsLivingCharacter(character) then
            return false
        end

        if Config.Targeting.IgnoreForceFieldTargets
            and HasForceField(character)
        then
            return false
        end

        local humanoid =
            character:FindFirstChildOfClass("Humanoid")

        if not humanoid or humanoid.Health <= 0 then
            return false
        end

        return true
    end

    local function FindNearestTarget(): Model?
        local bestCharacter: Model? = nil

        local bestDistance =
            Config.Targeting.MaximumDistance

        for _, player in ipairs(Players:GetPlayers()) do
            local character = player.Character

            if character
                and IsValidTarget(character)
            then
                local targetRoot =
                    GetCharacterRoot(character)

                if targetRoot then
                    local distance = (
                        targetRoot.Position - Root.Position
                    ).Magnitude

                    if distance < bestDistance then
                        local visible = true

                        if Config.Targeting.RequireLineOfSight then
                            visible = HasLineOfSight(targetRoot)
                        end

                        if visible then
                            bestDistance = distance
                            bestCharacter = character
                        end
                    end
                end
            end
        end

        if Config.Targeting.IgnoreNPCs then
            return bestCharacter
        end

        for _, candidate in ipairs(
            CollectionService:GetTagged("Combatant")
        ) do
            if candidate:IsA("Model")
                and candidate ~= NPC
                and not Players:GetPlayerFromCharacter(candidate)
                and IsValidTarget(candidate)
            then
                local candidateRoot =
                    GetCharacterRoot(candidate)

                if candidateRoot then
                    local distance = (
                        candidateRoot.Position - Root.Position
                    ).Magnitude

                    if distance < bestDistance then
                        bestDistance = distance
                        bestCharacter = candidate
                    end
                end
            end
        end

        return bestCharacter
    end

    local function BindTarget(character: Model?)
        if CurrentTarget == character then
            return
        end

        CurrentTarget = character
        TargetHumanoid = nil
        TargetRoot = nil

        if character then
            TargetHumanoid =
                character:FindFirstChildOfClass("Humanoid")

            TargetRoot = GetCharacterRoot(character)

            NPC:SetAttribute(
                "CompanionTarget",
                character.Name
            )
        else
            NPC:SetAttribute("CompanionTarget", "")
        end

        LastKnownTargetPosition = if TargetRoot
            then TargetRoot.Position
            else nil

        ThreatExpiresAt = 0

        NPC:SetAttribute("CompanionThreat", false)

        if IsBlocking then
            IsBlocking = false

            NPC:SetAttribute(
                "CompanionBlocking",
                false
            )

            SafeCall(function()
                CombatAction:Fire("BlockReleased", {
                    Target = character,
                })
            end)
        end
    end

    local function UpdateTargeting()
        local now = os.clock()

        if now - LastTargetScan
            < Config.Targeting.ScanInterval
        then
            return
        end

        LastTargetScan = now

        local target = FindNearestTarget()

        BindTarget(target)
    end

    ------------------------------------------------------------
    -- MODULE 5: PREDICTIVE COMBAT THREAT ANALYZER
    ------------------------------------------------------------

    local function IsThreatAnimation(
        track: AnimationTrack
    ): boolean
        local animation = track.Animation

        if not animation then
            return false
        end

        local name = string.lower(
            animation.Name or ""
        )

        if #name > Config.Threat.MaximumTrackNameLength then
            name = string.sub(
                name,
                1,
                Config.Threat.MaximumTrackNameLength
            )
        end

        for _, keyword in ipairs(
            Config.Threat.AnimationKeywords
        ) do
            if string.find(name, keyword, 1, true) then
                return true
            end
        end

        return false
    end

    local function GetTargetAnimator(
        character: Model
    ): Animator?
        local humanoid =
            character:FindFirstChildOfClass("Humanoid")

        if not humanoid then
            return nil
        end

        local animator =
            humanoid:FindFirstChildOfClass("Animator")

        return animator
    end

    local function EvaluateThreat(): boolean
        if not CurrentTarget or not TargetRoot then
            return false
        end

        if not IsValidTarget(CurrentTarget) then
            return false
        end

        local distance = (
            TargetRoot.Position - Root.Position
        ).Magnitude

        if distance > Config.Targeting.MaximumDistance then
            return false
        end

        local velocityMagnitude =
            TargetRoot.AssemblyLinearVelocity.Magnitude

        local highVelocity =
            velocityMagnitude > Config.Threat.VelocityThreshold

        local animationThreat = false

        local targetAnimator =
            GetTargetAnimator(CurrentTarget)

        if targetAnimator then
            local success, tracks = pcall(function()
                return targetAnimator:GetPlayingAnimationTracks()
            end)

            if success and tracks then
                for _, track in ipairs(tracks) do
                    local matched = false

                    local matchSuccess = pcall(function()
                        matched = track.IsPlaying
                            and IsThreatAnimation(track)
                    end)

                    if matchSuccess and matched then
                        animationThreat = true
                        break
                    end
                end
            end
        end

        local displacement =
            TargetRoot.Position - Root.Position

        local approaching = false

        if displacement.Magnitude > 0.01 then
            local towardNPC = -displacement.Unit

            local targetVelocity =
                TargetRoot.AssemblyLinearVelocity

            approaching =
                targetVelocity:Dot(towardNPC) > 0
        end

        return animationThreat
            or (highVelocity and approaching)
    end

    local function SetBlocking(enabled: boolean)
        if IsBlocking == enabled then
            return
        end

        IsBlocking = enabled

        NPC:SetAttribute(
            "CompanionBlocking",
            enabled
        )

        SafeCall(function()
            CombatAction:Fire(
                if enabled
                    then "BlockStarted"
                    else "BlockReleased",
                {
                    Target = CurrentTarget,
                    Timestamp = os.clock(),
                }
            )
        end)
    end

    local function UpdateThreatAnalysis()
        if not CurrentTarget or not TargetRoot then
            ThreatExpiresAt = 0

            NPC:SetAttribute(
                "CompanionThreat",
                false
            )

            SetBlocking(false)

            return
        end

        local now = os.clock()

        local threat = EvaluateThreat()

        if threat then
            ThreatExpiresAt =
                now + Config.Threat.ThreatHoldDuration
        end

        local threatActive =
            threat or now < ThreatExpiresAt

        NPC:SetAttribute(
            "CompanionThreat",
            threatActive
        )

        if threatActive then
            SetBlocking(true)

            Humanoid:Move(Vector3.zero, false)

            SetState(States.Parrying)
        elseif IsBlocking then
            if now - LastBlockUpdate
                >= Config.Threat.BlockCooldown
            then
                LastBlockUpdate = now
                SetBlocking(false)
            end
        end
    end

    ------------------------------------------------------------
    -- MODULE 6: DISTANCE-BASED COMBAT EXECUTOR
    ------------------------------------------------------------

    local function FireCombatAction(
        actionName: string,
        payload: { [string]: any }?
    )
        if not IsRunning then
            return
        end

        LastActionId += 1

        local actionPayload = payload or {}

        actionPayload.ActionId = LastActionId
        actionPayload.Target = CurrentTarget
        actionPayload.Timestamp = os.clock()

        SafeCall(function()
            CombatAction:Fire(
                actionName,
                actionPayload
            )
        end)
    end

    local function GetUsableTool(): Tool?
        for _, descendant in ipairs(
            NPC:GetDescendants()
        ) do
            if descendant:IsA("Tool")
                and descendant.Enabled
            then
                return descendant
            end
        end

        return nil
    end

    local function ExecuteToolCombo()
        local now = os.clock()

        if now - LastCombo
            < Config.Combat.ComboCooldown
        then
            return
        end

        LastCombo = now

        local tool = GetUsableTool()

        for index = 1,
            Config.Combat.ToolActivationCount do

            if not IsRunning then
                return
            end

            if not CurrentTarget or not TargetRoot then
                return
            end

            if not IsValidTarget(CurrentTarget) then
                return
            end

            local currentDistance = (
                TargetRoot.Position - Root.Position
            ).Magnitude

            if currentDistance
                > Config.Combat.AttackDistance
            then
                return
            end

            FireCombatAction("ComboStep", {
                Step = index,
                TotalSteps =
                    Config.Combat.ToolActivationCount,
            })

            if tool then
                FireCombatAction("ToolAttackRequested", {
                    Tool = tool,
                    Step = index,
                })
            end

            if index
                < Config.Combat.ToolActivationCount
            then
                task.wait(
                    Config.Combat.ToolActivationInterval
                )
            end
        end
    end

    local function ExecuteSkillSequence()
        local now = os.clock()

        if now - LastSkillActivation
            < Config.Combat.SkillCooldown
        then
            return
        end

        LastSkillActivation = now

        for _, skillName in ipairs(
            Config.Combat.SkillNames
        ) do
            if not IsRunning then
                return
            end

            if not CurrentTarget or not TargetRoot then
                return
            end

            if not IsValidTarget(CurrentTarget) then
                return
            end

            local distance = (
                TargetRoot.Position - Root.Position
            ).Magnitude

            if distance
                > Config.Combat.AttackDistance
            then
                return
            end

            FireCombatAction("SkillRequested", {
                SkillName = skillName,
            })

            task.wait(0.08)
        end
    end

    local function ExecuteCombat()
        if not CurrentTarget or not TargetRoot then
            SetState(States.Idling)
            return
        end

        if not IsValidTarget(CurrentTarget) then
            BindTarget(nil)
            SetState(States.Idling)
            return
        end

        local displacement =
            TargetRoot.Position - Root.Position

        local distance = displacement.Magnitude

        if distance > Config.Targeting.MaximumDistance then
            SetState(States.Idling)

            Humanoid:Move(Vector3.zero, false)

            return
        end

        if distance > Config.Combat.AttackDistance then
            if not IsBlocking then
                SetState(States.Chasing)
            end

            UpdateNavigation()

            return
        end

        Humanoid:Move(Vector3.zero, false)

        if IsBlocking then
            return
        end

        SetState(States.Attacking)

        task.spawn(function()
            SafeCall(function()
                ExecuteToolCombo()
            end)
        end)

        task.spawn(function()
            SafeCall(function()
                ExecuteSkillSequence()
            end)
        end)
    end

    ------------------------------------------------------------
    -- STATE MACHINE DISPATCH
    ------------------------------------------------------------

    local function UpdateStateMachine()
        if not IsRunning then
            return
        end

        if Humanoid.Health <= 0 or not Root.Parent then
            return
        end

        if not CurrentTarget or not TargetRoot then
            SetState(States.Idling)

            Humanoid:Move(Vector3.zero, false)

            SetBlocking(false)

            return
        end

        if not IsValidTarget(CurrentTarget) then
            BindTarget(nil)

            SetState(States.Idling)

            return
        end

        if IsBlocking then
            SetState(States.Parrying)
            return
        end

        ExecuteCombat()
    end

    ------------------------------------------------------------
    -- CLEANUP ROUTINE
    ------------------------------------------------------------

    local CleanupStarted = false

    local function Cleanup()
        if CleanupStarted then
            return
        end

        CleanupStarted = true
        IsRunning = false

        CurrentState = States.Disabled

        SafeCall(function()
            SetBlocking(false)
        end)

        NPC:SetAttribute(
            "CompanionState",
            States.Disabled
        )

        NPC:SetAttribute("CompanionThreat", false)
        NPC:SetAttribute("CompanionBlocking", false)
        NPC:SetAttribute("CompanionTarget", "")

        for _, connection in ipairs(Connections) do
            SafeCall(function()
                connection:Disconnect()
            end)
        end

        table.clear(Connections)

        SafeCall(function()
            Humanoid:Move(Vector3.zero, false)

            Humanoid.WalkSpeed = OriginalWalkSpeed

            Humanoid.AutoRotate = OriginalAutoRotate
        end)

        SafeCall(function()
            Root.AssemblyLinearVelocity = Vector3.zero

            Root.AssemblyAngularVelocity = Vector3.zero
        end)

        RestoreCollisionState()

        for character in pairs(Highlights) do
            RemoveHighlight(character)
        end

        table.clear(Highlights)

        SafeCall(function()
            DebugFolder:Destroy()
        end)

        SafeCall(function()
            CombatAction:Destroy()
        end)

        SafeCall(function()
            CleanupEvent:Destroy()
        end)

        print(
            "[CombatCompanion] Cleanup completed."
        )
    end

    ------------------------------------------------------------
    -- PROTECTED EXECUTION THREAD
    ------------------------------------------------------------

    TrackConnection(
        CleanupEvent.Event:Connect(function()
            Cleanup()
        end)
    )

    TrackConnection(
        Humanoid.Died:Connect(function()
            Cleanup()
        end)
    )

    TrackConnection(
        NPC.AncestryChanged:Connect(function(_, parent)
            if parent == nil then
                Cleanup()
            end
        end)
    )

    local MainThread = task.spawn(function()
        local lastHighlightRefresh = 0

        while IsRunning do
            local success, errorMessage = xpcall(
                function()
                    local now = os.clock()

                    if Humanoid.Health <= 0 then
                        Cleanup()
                        return
                    end

                    UpdateTargeting()

                    UpdateThreatAnalysis()

                    UpdateStateMachine()

                    UpdateAntiStuck()

                    InspectCharacterCollision()

                    if now - lastHighlightRefresh
                        >= Config.Debug.RefreshInterval
                    then
                        lastHighlightRefresh = now

                        SafeCall(function()
                            RefreshHighlights()
                        end)
                    end
                end,
                debug.traceback
            )

            if not success then
                warn(
                    "[CombatCompanion] Main loop error:\n",
                    errorMessage
                )
            end

            task.wait(
                Config.Threat.UpdateInterval
            )
        end
    end)

    return {
        Cleanup = Cleanup,

        CombatAction = CombatAction,

        State = function()
            return CurrentState
        end,

        Target = function()
            return CurrentTarget
        end,

        IsRunning = function()
            return IsRunning
        end,

        MainThread = MainThread,
    }
end

------------------------------------------------------------
-- STARTUP GUARD
------------------------------------------------------------

local CompanionController = nil

local success, startupError = xpcall(
    function()
        CompanionController = StartCompanion()
    end,
    debug.traceback
)

if not success then
    warn(
        "[CombatCompanion] Startup failed:\n",
        startupError
    )
end
