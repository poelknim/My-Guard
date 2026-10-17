-- LocalScript: KillerProximityZoneAndAdvancedESP (V27 - Adaptive Motion Prediction)
-- Perubahan utama:
-- 1. Mengganti offset tetap MoveDirection * 20 dengan prediksi berdasarkan riwayat posisi.
-- 2. Mengestimasi kecepatan dan akselerasi dari posisi HumanoidRootPart.
-- 3. Mendeteksi perubahan arah dan memendekkan waktu prediksi saat berbelok.
-- 4. Membatasi akselerasi dan menghaluskan estimasi untuk mengurangi jitter.
-- 5. Mengukur galat prediksi setelah horizon prediksi berlalu.
-- Bagian UI, vignette, deteksi status, Highlight, Ghost, dan garis arah dipertahankan.

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")
local TweenService = game:GetService("TweenService")

local player = Players.LocalPlayer
local camera = Workspace.CurrentCamera

-- Konfigurasi Jangkauan
local TOTAL_ACTIVE_RANGE = 150
local DOME_VISIBLE_RANGE = 80
local isSkillActive = true

-- ==========================================
-- KONFIGURASI PREDIKSI ADAPTIF
-- ==========================================
local PREDICTION_BASE_TIME = 0.18       -- Horizon normal, dalam detik
local PREDICTION_MAX_TIME = 0.30        -- Batas horizon saat gerakan stabil
local PREDICTION_TURN_TIME = 0.04       -- Horizon singkat ketika berbelok
local PREDICTION_UNCERTAIN_TIME = 0.06  -- Horizon ketika data gerak tidak stabil
local MIN_TRACK_SPEED = 1.0             -- Kecepatan minimum untuk estimasi arah
local TURN_ANGLE_DEGREES = 35           -- Sudut minimum untuk menandai belokan
local MAX_ACCELERATION = 120            -- Batas akselerasi estimasi, studs/s^2
local VELOCITY_SMOOTHING = 0.35         -- 0..1; lebih kecil = lebih halus
local ACCELERATION_SMOOTHING = 0.25     -- 0..1; lebih kecil = lebih halus
local GHOST_LERP_SPEED = 10              -- Kecepatan pendekatan Ghost per detik
local PREDICTION_ERROR_SAMPLE_LIMIT = 40

-- 1. Membuat UI & Efek Vignette
local screenGui = Instance.new("ScreenGui")
screenGui.Name = "KillerZoneGui"
screenGui.ResetOnSpawn = false
screenGui.IgnoreGuiInset = true
screenGui.ScreenInsets = Enum.ScreenInsets.None
screenGui.Parent = player:WaitForChild("PlayerGui")

local circleButton = Instance.new("TextButton")
circleButton.Name = "SkillCircleButton"
circleButton.Size = UDim2.new(0, 60, 0, 60)
circleButton.Position = UDim2.new(1, -70, 0, 56)
circleButton.AnchorPoint = Vector2.new(0, 0)
circleButton.BackgroundColor3 = Color3.fromRGB(40, 40, 40)
circleButton.Text = "ESP"
circleButton.TextColor3 = Color3.fromRGB(255, 255, 255)
circleButton.TextSize = 14
circleButton.Font = Enum.Font.GothamBold
circleButton.Parent = screenGui

local uiCorner = Instance.new("UICorner")
uiCorner.CornerRadius = UDim.new(1, 0)
uiCorner.Parent = circleButton

local uiStroke = Instance.new("UIStroke")
uiStroke.Color = Color3.fromRGB(0, 255, 200)
uiStroke.Thickness = 2
uiStroke.Parent = circleButton

-- ==========================================
-- SISTEM VIGNETTE
-- ==========================================
local vignetteFolder = Instance.new("Folder")
vignetteFolder.Name = "VignetteSystem"
vignetteFolder.Parent = screenGui

local function createGradientEdge(name, size, pos, anchor, rot)
    local frame = Instance.new("Frame")
    frame.Name = name
    frame.Size = size
    frame.Position = pos
    frame.AnchorPoint = anchor
    frame.BackgroundColor3 = Color3.fromRGB(15, 0, 0)
    frame.BorderSizePixel = 0
    frame.BackgroundTransparency = 1
    frame.ZIndex = 1

    local gradient = Instance.new("UIGradient")
    gradient.Rotation = rot
    gradient.Transparency = NumberSequence.new({
        NumberSequenceKeypoint.new(0, 0),
        NumberSequenceKeypoint.new(1, 1)
    })
    gradient.Parent = frame
    frame.Parent = vignetteFolder
    return frame
end

local vTop = createGradientEdge("Top", UDim2.new(1, 0, 0.3, 0), UDim2.new(0, 0, 0, 0), Vector2.new(0, 0), 90)
local vBottom = createGradientEdge("Bottom", UDim2.new(1, 0, 0.3, 0), UDim2.new(0, 0, 1, 0), Vector2.new(0, 1), 270)
local vLeft = createGradientEdge("Left", UDim2.new(0.25, 0, 1, 0), UDim2.new(0, 0, 0, 0), Vector2.new(0, 0), 0)
local vRight = createGradientEdge("Right", UDim2.new(0.25, 0, 1, 0), UDim2.new(1, 0, 0, 0), Vector2.new(1, 0), 180)

local vignetteFrames = {vTop, vBottom, vLeft, vRight}
local vignetteState = false

local function updateVignette(active)
    if vignetteState == active then return end
    vignetteState = active

    local targetTrans = active and 0.65 or 1
    local tweenInfo = TweenInfo.new(0.5, Enum.EasingStyle.Sine, Enum.EasingDirection.Out)

    for _, frame in ipairs(vignetteFrames) do
        TweenService:Create(frame, tweenInfo, {BackgroundTransparency = targetTrans}):Play()
    end
end

-- ==========================================
-- 2. Efek Visual Kubah Bulat
-- ==========================================
local domePart = Instance.new("Part")
domePart.Name = "KillerDomeZone"
domePart.Shape = Enum.PartType.Ball
domePart.Size = Vector3.new(DOME_VISIBLE_RANGE * 2, DOME_VISIBLE_RANGE * 2, DOME_VISIBLE_RANGE * 2)
domePart.Anchored = true
domePart.CanCollide = false
domePart.CanQuery = false
domePart.CanTouch = false
domePart.Transparency = 1
domePart.Color = Color3.fromRGB(0, 180, 255)
domePart.Material = Enum.Material.Glass
domePart.Parent = camera

local function getKiller()
    for _, p in ipairs(Players:GetPlayers()) do
        if p ~= player and p.Character and p.Character:FindFirstChild("HumanoidRootPart") then
            if p:GetAttribute("IsKiller") == true or (p.Team and p.Team.Name == "Killer") then
                return p.Character
            end
        end
    end
    for _, p in ipairs(Players:GetPlayers()) do
        if p ~= player and p.Character and p.Character:FindFirstChild("HumanoidRootPart") then
            return p.Character
        end
    end
    return nil
end

local function getKillerActionState(character, humanoid)
    local state = "Neutral"

    local hitAttributes = {"IsHitting", "Attacking", "M1", "M2", "Punching", "Swinging", "Combat"}
    local skillAttributes = {"IsSkilling", "UsingSkill", "Dashing", "Blocking", "HeavyAttacking"}
    for _, attr in ipairs(hitAttributes) do
        if character:GetAttribute(attr) then return "Hit" end
    end
    for _, attr in ipairs(skillAttributes) do
        if character:GetAttribute(attr) then return "Skill" end
    end

    for _, obj in ipairs(character:GetChildren()) do
        if obj:IsA("BoolValue") and obj.Value == true then
            local vName = string.lower(obj.Name)
            if string.find(vName, "skill") or string.find(vName, "dash") or string.find(vName, "block") or string.find(vName, "heavy") then
                return "Skill"
            elseif string.find(vName, "attack") or string.find(vName, "hit") or string.find(vName, "m1") or string.find(vName, "swing") or string.find(vName, "combat") then
                return "Hit"
            end
        end
    end

    local animator = humanoid:FindFirstChildOfClass("Animator")
    if animator then
        pcall(function()
            for _, track in ipairs(animator:GetPlayingAnimationTracks()) do
                if track.IsPlaying and track.Weight > 0.05 then
                    if track.Animation then
                        local animName = string.lower(track.Animation.Name)
                        if string.find(animName, "skill") or string.find(animName, "magic") or string.find(animName, "dash") or string.find(animName, "heavy") or string.find(animName, "ult") then
                            state = "Skill"
                            return
                        elseif string.find(animName, "hit") or string.find(animName, "attack") or string.find(animName, "punch") or string.find(animName, "slash") or string.find(animName, "swing") or string.find(animName, "m1") then
                            state = "Hit"
                            return
                        end
                    end

                    local priority = track.Priority
                    if priority == Enum.AnimationPriority.Action or priority == Enum.AnimationPriority.Action2 or priority == Enum.AnimationPriority.Action3 or priority == Enum.AnimationPriority.Action4 then
                        state = "Hit"
                        return
                    end
                end
            end
        end)
    end

    return state
end

-- ==========================================
-- MOTION TRACKER + PREDIKSI ADAPTIF
-- ==========================================
local motionTrackers = {}
local predictionErrorSamples = {}

local function clampVectorMagnitude(vector, maxMagnitude)
    local magnitude = vector.Magnitude
    if magnitude > maxMagnitude and magnitude > 0 then
        return vector.Unit * maxMagnitude
    end
    return vector
end

local function getMotionPrediction(character, rootPart, now)
    local position = rootPart.Position
    local tracker = motionTrackers[character]

    if not tracker then
        tracker = {
            lastPosition = position,
            lastTime = now,
            velocity = Vector3.zero,
            acceleration = Vector3.zero,
            lastDirection = Vector3.zero,
            turnDetected = false,
            uncertain = true,
            horizon = PREDICTION_UNCERTAIN_TIME,
            pendingSamples = {}
        }
        motionTrackers[character] = tracker
        return position, Vector3.zero, tracker
    end

    local dt = now - tracker.lastTime
    if dt <= 0 or dt > 0.5 then
        -- Setelah jeda observasi yang terlalu besar, hindari menghitung
        -- kecepatan/akselerasi dari sampel yang tidak sebanding.
        tracker.lastPosition = position
        tracker.lastTime = now
        tracker.velocity = Vector3.zero
        tracker.acceleration = Vector3.zero
        tracker.lastDirection = Vector3.zero
        tracker.turnDetected = false
        tracker.uncertain = true
        tracker.horizon = PREDICTION_UNCERTAIN_TIME
        return position, Vector3.zero, tracker
    end

    local rawVelocity = (position - tracker.lastPosition) / dt
    local previousVelocity = tracker.velocity
    local velocity = previousVelocity:Lerp(rawVelocity, VELOCITY_SMOOTHING)
    local rawAcceleration = (velocity - previousVelocity) / dt
    rawAcceleration = clampVectorMagnitude(rawAcceleration, MAX_ACCELERATION)
    local acceleration = tracker.acceleration:Lerp(rawAcceleration, ACCELERATION_SMOOTHING)

    local speed = velocity.Magnitude
    local previousSpeed = previousVelocity.Magnitude
    local turnDetected = false

    if speed >= MIN_TRACK_SPEED and previousSpeed >= MIN_TRACK_SPEED then
        local dot = math.clamp(previousVelocity.Unit:Dot(velocity.Unit), -1, 1)
        local angle = math.deg(math.acos(dot))
        turnDetected = angle >= TURN_ANGLE_DEGREES
    end

    -- Tandai data tidak stabil ketika kecepatan hasil observasi berbeda
    -- jauh dari estimasi sebelumnya.
    local velocityDifference = (rawVelocity - previousVelocity).Magnitude
    local uncertain = turnDetected or velocityDifference > math.max(12, previousSpeed * 1.25)

    local horizon = PREDICTION_BASE_TIME
    if uncertain then
        horizon = turnDetected and PREDICTION_TURN_TIME or PREDICTION_UNCERTAIN_TIME
    else
        -- Gerakan yang stabil boleh memakai horizon lebih panjang,
        -- tetapi tetap dibatasi oleh PREDICTION_MAX_TIME.
        horizon = math.clamp(PREDICTION_BASE_TIME + math.min(speed * 0.005, 0.12), PREDICTION_BASE_TIME, PREDICTION_MAX_TIME)
    end

    -- Jika karakter hampir berhenti, jangan terus membawa prediksi lama.
    if speed < MIN_TRACK_SPEED then
        horizon = 0
        acceleration = Vector3.zero
        velocity = Vector3.zero
    end

    -- Simpan sampel prediksi untuk evaluasi setelah horizon berlalu.
    table.insert(tracker.pendingSamples, {
        predictedPosition = position + velocity * horizon + acceleration * (0.5 * horizon * horizon),
        observedAt = now,
        evaluateAt = now + horizon,
        horizon = horizon
    })

    -- Batasi jumlah sampel yang menunggu evaluasi.
    while #tracker.pendingSamples > PREDICTION_ERROR_SAMPLE_LIMIT do
        table.remove(tracker.pendingSamples, 1)
    end

    -- Evaluasi galat terhadap posisi yang benar-benar teramati.
    for i = #tracker.pendingSamples, 1, -1 do
        local sample = tracker.pendingSamples[i]
        if now >= sample.evaluateAt then
            local errorMagnitude = (position - sample.predictedPosition).Magnitude
            table.insert(predictionErrorSamples, errorMagnitude)
            if #predictionErrorSamples > PREDICTION_ERROR_SAMPLE_LIMIT then
                table.remove(predictionErrorSamples, 1)
            end
            table.remove(tracker.pendingSamples, i)
        end
    end

    tracker.lastPosition = position
    tracker.lastTime = now
    tracker.velocity = velocity
    tracker.acceleration = acceleration
    tracker.lastDirection = speed >= MIN_TRACK_SPEED and velocity.Unit or Vector3.zero
    tracker.turnDetected = turnDetected
    tracker.uncertain = uncertain
    tracker.horizon = horizon

    local predictedPosition = position + velocity * horizon + acceleration * (0.5 * horizon * horizon)
    return predictedPosition, velocity, tracker
end

local function getAveragePredictionError()
    if #predictionErrorSamples == 0 then
        return nil
    end

    local total = 0
    for _, errorMagnitude in ipairs(predictionErrorSamples) do
        total += errorMagnitude
    end
    return total / #predictionErrorSamples
end

local killerHighlights = {}
local espGhosts = {}
local directionLines = {}
local thinDirectionLines = {}
local ghostPartsCache = {}

local function clearAllESP()
    for _, hl in pairs(killerHighlights) do
        if hl then hl:Destroy() end
    end
    killerHighlights = {}

    for _, ghost in pairs(espGhosts) do
        if ghost then ghost:Destroy() end
    end
    espGhosts = {}

    for _, line in pairs(directionLines) do
        if line then line:Destroy() end
    end
    directionLines = {}

    for _, line in pairs(thinDirectionLines) do
        if line then line:Destroy() end
    end
    thinDirectionLines = {}

    ghostPartsCache = {}
    motionTrackers = {}
    predictionErrorSamples = {}

    domePart.Transparency = 1
    updateVignette(false)
end

RunService.RenderStepped:Connect(function(dt)
    local character = player.Character
    if not character or not character:FindFirstChild("HumanoidRootPart") then
        clearAllESP()
        return
    end

    local rootPart = character.HumanoidRootPart
    local killerChar = getKiller()

    if killerChar and killerChar:FindFirstChild("HumanoidRootPart") and killerChar:FindFirstChildOfClass("Humanoid") then
        local killerRoot = killerChar.HumanoidRootPart
        local killerHumanoid = killerChar:FindFirstChildOfClass("Humanoid")
        local distance = (rootPart.Position - killerRoot.Position).Magnitude

        if distance <= TOTAL_ACTIVE_RANGE and isSkillActive then
            circleButton.BackgroundColor3 = Color3.fromRGB(0, 150, 100)
            domePart.Position = killerRoot.Position
            domePart.Transparency = 0.93

            if distance <= DOME_VISIBLE_RANGE then
                updateVignette(true)
            else
                updateVignette(false)
            end

            if not killerHighlights[killerChar] then
                local highlight = Instance.new("Highlight")
                highlight.Name = "KillerChams"
                highlight.Adornee = killerChar
                highlight.FillColor = Color3.fromRGB(255, 30, 30)
                highlight.FillTransparency = 0.8
                highlight.OutlineColor = Color3.fromRGB(255, 255, 255)
                highlight.OutlineTransparency = 0
                highlight.Parent = killerChar
                killerHighlights[killerChar] = highlight
            end

            local actionState = getKillerActionState(killerChar, killerHumanoid)

            -- ==========================================
            -- 3. ESP GHOST PREDICTION (ADAPTIF)
            -- ==========================================
            local now = os.clock()
            local predictedPos, estimatedVelocity, motionTracker = getMotionPrediction(killerChar, killerRoot, now)
            local measuredSpeed = estimatedVelocity.Magnitude
            local isMoving = measuredSpeed > MIN_TRACK_SPEED or killerHumanoid.MoveDirection.Magnitude > 0.1

            local targetCFrame
            local shouldShowGhost = false

            if isMoving then
                -- Ketika ada data kecepatan yang cukup, gunakan prediksi adaptif.
                -- Jika belum ada riwayat gerak, gunakan arah MoveDirection hanya
                -- untuk orientasi, bukan offset jarak tetap.
                local facingDirection
                if measuredSpeed > MIN_TRACK_SPEED then
                    facingDirection = estimatedVelocity.Unit
                else
                    facingDirection = killerHumanoid.MoveDirection.Unit
                    predictedPos = killerRoot.Position
                end

                if facingDirection.Magnitude < 0.001 then
                    facingDirection = killerRoot.CFrame.LookVector
                end

                local targetRot = CFrame.lookAt(predictedPos, predictedPos + facingDirection).Rotation
                targetCFrame = CFrame.new(predictedPos) * targetRot
                shouldShowGhost = true
            elseif actionState ~= "Neutral" then
                -- Saat ada aksi tetapi tidak terukur bergerak, tampilkan Ghost
                -- dengan offset sangat pendek berdasarkan arah hadap saat ini.
                local shortActionHorizon = 0.08
                local actionPos = killerRoot.Position + (killerRoot.AssemblyLinearVelocity * shortActionHorizon)
                targetCFrame = CFrame.new(actionPos) * killerRoot.CFrame.Rotation
                shouldShowGhost = true
            else
                local behindPos = killerRoot.Position - (killerRoot.CFrame.LookVector * 3)
                targetCFrame = CFrame.new(behindPos) * killerRoot.CFrame.Rotation
                shouldShowGhost = false
            end

            -- CLONING KARAKTER (HITBOX HIDDEN & NO-CLIP)
            if not espGhosts[killerChar] or not espGhosts[killerChar].Parent then
                local previousArchivable = killerChar.Archivable
                killerChar.Archivable = true
                local success, ghostClone = pcall(function()
                    return killerChar:Clone()
                end)
                killerChar.Archivable = previousArchivable

                if success and ghostClone then
                    ghostClone.Name = "GhostPredictionESP"
                    ghostPartsCache[killerChar] = {}

                    for _, desc in ipairs(ghostClone:GetChildren()) do
                        if desc:IsA("Tool") then
                            desc:Destroy()
                        end
                    end

                    for _, desc in ipairs(ghostClone:GetDescendants()) do
                        if desc:IsA("BasePart") then
                            desc.Anchored = true
                            desc.CanCollide = false
                            desc.CanQuery = false
                            desc.CanTouch = false
                            desc.CastShadow = false
                            desc.Massless = true

                            table.insert(ghostPartsCache[killerChar], desc)

                            local originalPart = killerChar:FindFirstChild(desc.Name, true)
                            local lowerName = string.lower(desc.Name)
                            local isHitbox = string.find(lowerName, "hitbox") or string.find(lowerName, "collider") or string.find(lowerName, "rootpart")
                            local isOriginalHidden = originalPart and originalPart:IsA("BasePart") and originalPart.Transparency >= 0.5

                            if isHitbox or isOriginalHidden or desc.Name == "HumanoidRootPart" or desc.Name == "LowerTorso" then
                                desc.Transparency = 1
                                desc:SetAttribute("GhostHidden", true)
                            else
                                desc.Material = Enum.Material.ForceField
                                desc.Color = Color3.fromRGB(255, 140, 0)
                                desc.Transparency = 0.1
                                desc:SetAttribute("GhostVisible", true)
                            end
                        elseif desc:IsA("Texture") or desc:IsA("SurfaceAppearance") or desc:IsA("Script") or desc:IsA("LocalScript") then
                            desc:Destroy()
                        end
                    end

                    local ghostHum = ghostClone:FindFirstChildOfClass("Humanoid")
                    if ghostHum then
                        ghostHum.DisplayDistanceType = Enum.HumanoidDisplayDistanceType.None
                        ghostHum.HealthDisplayType = Enum.HumanoidHealthDisplayType.AlwaysOff
                        ghostHum.RequiresNeck = false
                        ghostHum.EvaluateStateMachine = false
                        for _, state in pairs(Enum.HumanoidStateType:GetEnumItems()) do
                            pcall(function()
                                ghostHum:SetStateEnabled(state, false)
                            end)
                        end
                    end

                    local ghostHighlight = Instance.new("Highlight")
                    ghostHighlight.Adornee = ghostClone
                    ghostHighlight.FillColor = Color3.fromRGB(255, 165, 0)
                    ghostHighlight.FillTransparency = 0.8
                    ghostHighlight.OutlineColor = Color3.fromRGB(0, 255, 255)
                    ghostHighlight.OutlineTransparency = 0.2
                    ghostHighlight.Parent = ghostClone

                    ghostClone:PivotTo(killerRoot.CFrame)
                    ghostClone.Parent = camera
                    espGhosts[killerChar] = ghostClone
                end
            else
                local ghost = espGhosts[killerChar]
                if ghost and targetCFrame then
                    -- Lerp berbasis dt agar relatif konsisten pada FPS berbeda.
                    local alpha = 1 - math.exp(-GHOST_LERP_SPEED * math.max(dt, 0))
                    local currentGhostCFrame = ghost:GetPivot()
                    local nextGhostCFrame = currentGhostCFrame:Lerp(targetCFrame, math.clamp(alpha, 0, 1))
                    ghost:PivotTo(nextGhostCFrame)

                    local ghostHighlight = ghost:FindFirstChildOfClass("Highlight")
                    if ghostHighlight then
                        ghostHighlight.Enabled = shouldShowGhost
                    end

                    for _, desc in ipairs(ghost:GetDescendants()) do
                        if desc:IsA("BasePart") then
                            if desc:GetAttribute("GhostVisible") then
                                desc.Transparency = shouldShowGhost and 0.1 or 1
                            end
                        elseif desc:IsA("Decal") then
                            if desc.Parent and desc.Parent:GetAttribute("GhostVisible") then
                                desc.Transparency = shouldShowGhost and 0.1 or 1
                            else
                                desc.Transparency = 1
                            end
                        end
                    end

                    -- SINKRONISASI ANIMASI LIVE
                    if shouldShowGhost then
                        local realAnimator = killerHumanoid:FindFirstChildOfClass("Animator")
                        local ghostHumanoid = ghost:FindFirstChildOfClass("Humanoid")
                        local ghostAnimator = ghostHumanoid and ghostHumanoid:FindFirstChildOfClass("Animator")

                        if realAnimator and ghostAnimator then
                            pcall(function()
                                local playingReal = realAnimator:GetPlayingAnimationTracks()
                                local playingGhost = ghostAnimator:GetPlayingAnimationTracks()

                                local ghostTracksLookup = {}
                                for _, gTrack in ipairs(playingGhost) do
                                    if gTrack.Animation then
                                        ghostTracksLookup[gTrack.Animation.AnimationId] = gTrack
                                    end
                                end

                                local activeIds = {}
                                for _, rTrack in ipairs(playingReal) do
                                    if rTrack.Animation and rTrack.IsPlaying then
                                        local animId = rTrack.Animation.AnimationId
                                        activeIds[animId] = true
                                        local gTrack = ghostTracksLookup[animId]

                                        if not gTrack then
                                            gTrack = ghostAnimator:LoadAnimation(rTrack.Animation)
                                            gTrack:Play()
                                            ghostTracksLookup[animId] = gTrack
                                        end

                                        if math.abs(gTrack.TimePosition - rTrack.TimePosition) > 0.05 then
                                            gTrack.TimePosition = rTrack.TimePosition
                                        end
                                        gTrack:AdjustSpeed(rTrack.Speed)
                                        gTrack:AdjustWeight(rTrack.Weight)
                                    end
                                end

                                for animId, gTrack in pairs(ghostTracksLookup) do
                                    if not activeIds[animId] then
                                        gTrack:Stop()
                                    end
                                end
                            end)
                        end
                    end
                end
            end

            -- ==========================================
            -- 4. ESP LINES (3D VECTOR & FLAT ROOT AXIS)
            -- ==========================================
            local lineLength = DOME_VISIBLE_RANGE

            local directionLine = directionLines[killerChar]
            if not directionLine then
                directionLine = Instance.new("Part")
                directionLine.Name = "Killer3DDirectionLine"
                directionLine.Anchored = true
                directionLine.CanCollide = false
                directionLine.CanQuery = false
                directionLine.CanTouch = false
                directionLine.CastShadow = false
                directionLine.Material = Enum.Material.Neon
                directionLine.Size = Vector3.new(0.2, 0.2, lineLength)
                directionLine.Parent = camera
                directionLines[killerChar] = directionLine
            end

            if actionState == "Neutral" then
                directionLine.Color = Color3.fromRGB(0, 255, 255)
            elseif actionState == "Hit" then
                directionLine.Color = Color3.fromRGB(255, 0, 0)
            elseif actionState == "Skill" then
                directionLine.Color = Color3.fromRGB(255, 0, 255)
            end

            local head = killerChar:FindFirstChild("Head")
            local startPos = head and head.Position or (killerRoot.Position + Vector3.new(0, 1, 0))
            local headLook = head and head.CFrame.LookVector or killerRoot.CFrame.LookVector
            if headLook.Magnitude < 0.001 then
                headLook = killerRoot.CFrame.LookVector
            end
            local blendedVector = headLook.Unit
            local endPos3D = startPos + (blendedVector * lineLength)

            directionLine.Size = Vector3.new(0.2, 0.2, lineLength)
            directionLine.CFrame = CFrame.lookAt(startPos, endPos3D) * CFrame.new(0, 0, -lineLength / 2)

            local thinLine = thinDirectionLines[killerChar]
            if not thinLine then
                thinLine = Instance.new("Part")
                thinLine.Name = "KillerZAxisThinLine"
                thinLine.Anchored = true
                thinLine.CanCollide = false
                thinLine.CanQuery = false
                thinLine.CanTouch = false
                thinLine.CastShadow = false
                thinLine.Material = Enum.Material.Neon
                thinLine.Color = Color3.fromRGB(255, 255, 255)
                thinLine.Size = Vector3.new(0.05, 0.05, lineLength)
                thinLine.Parent = camera
                thinDirectionLines[killerChar] = thinLine
            end

            local rootPos = killerRoot.Position + Vector3.new(0, 1, 0)
            local rootVector = killerRoot.CFrame.LookVector
            local rootEndPos = rootPos + (rootVector * lineLength)

            thinLine.Size = Vector3.new(0.05, 0.05, lineLength)
            thinLine.CFrame = CFrame.lookAt(rootPos, rootEndPos) * CFrame.new(0, 0, -lineLength / 2)
        else
            clearAllESP()
            circleButton.BackgroundColor3 = Color3.fromRGB(40, 40, 40)
        end
    else
        clearAllESP()
        circleButton.BackgroundColor3 = Color3.fromRGB(40, 40, 40)
    end
end)

-- ==========================================
-- 5. PENERAPAN NO-CLIP PADA GHOST
-- ==========================================
RunService.Stepped:Connect(function()
    for _, partsList in pairs(ghostPartsCache) do
        for _, part in ipairs(partsList) do
            if part and part.Parent then
                part.CanCollide = false
                part.CanTouch = false
                part.CanQuery = false
            end
        end
    end
end)

-- Catatan:
-- getAveragePredictionError() mengembalikan rata-rata galat prediksi (studs)
-- jika sampel evaluasi tersedia. Fungsi ini tidak mengubah tampilan UI.
