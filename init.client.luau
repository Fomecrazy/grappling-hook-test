-- discord: .fome roblox: fomecrazy

local Players = game:GetService("Players");
local RunService = game:GetService("RunService");
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService");
local Workspace = game:GetService("Workspace")

-- Signal is derived from one of the open sourced signal libraries,
-- i don't however remember which one i made this one from, pretty sure GoodSignal
-- so i hope it doesnt require documentation
local Signal = {};
Signal.__index = Signal;

function Signal.new()
	local self = setmetatable({ waitingThreads = {} }, Signal);
	return self;
end

function Signal:Fire(...)
	local args = {...};

	local signalListeners = self.connection;
	while signalListeners do
		task.spawn(signalListeners._fn, unpack(args));
		signalListeners = signalListeners._next;
	end
end

function Signal:Connect(callback)
	if not typeof(callback) == "function" then return end
	
	local connection;
	connection = {
		_fn = callback,
		_next = self.connection,
		Disconnect = function()
			return self:Disconnect(connection);
		end
	};

	self.connection = connection;
	return self.connection;
end

function Signal:Once(callback)
	local done = false;
	local c;

	c = self:Connect(function(...)
		if done then return end
		done = true;

		c.Disconnect();
		callback(...);
	end);

	return c;
end

function Signal:Disconnect(connection)
	if self.connection == connection then
		self.connection = self.connection._next;
	else
		local prev = self.connection;

		while prev and prev._next ~= connection do
			prev = prev._next;
		end

		if prev then
			prev._next = connection._next;
		end
	end
end


local attachmentPointsFolder: Folder = Workspace:FindFirstChild("attachmentPoints");
if not attachmentPointsFolder then
	attachmentPointsFolder = Instance.new("Folder");
	attachmentPointsFolder.Name = "attachmentPoints";
end

local TERMINAL_VELOCITY = 100;
local TWEEN_INFO = TweenInfo.new(0.2)

-- in studs
local MIN_LENGTH = 10;
local MAX_REACH_DISTANCE = 200;

local params = RaycastParams.new();
params.FilterType = Enum.RaycastFilterType.Exclude;

local p = Players.LocalPlayer;
local mouse = p:GetMouse();

local closestAttachmentPoint: BasePart;
local activeAttachmentUis: { [Model]: BillboardGui } = {};
local isAttached = false;

local onRetracted = Signal.new();
local closestAttachmentPointChanged = Signal.new();

--[[
	We need to hide all the attachment points behind obstacles,
	so we need a helper function for that.
	The raycasts can hit the player's character, so we first update the
	RaycastParams filter instances as the player character under the Exclude filter type.
	Next we get the position of both the attachment point and the character,
	calculate the unit of them, and cast a ray from the character to the attachment point.
	We return whether the hit instance is a descendant of the attachment point.
]]
local function isAttachmentPointInSight(char: Model, attachmentPoint: Model)
	if not char or not attachmentPoint then return end

	if table.find(params.FilterDescendantsInstances, char) == nil then
		params.FilterDescendantsInstances = {char};
	end

	local attachmentPos = attachmentPoint:GetPivot().Position;
	local charPos = char:GetPivot().Position;

	local u = attachmentPos - charPos;
	local raycast = Workspace:Raycast(charPos, u.Unit * u.Magnitude, params);

	return raycast and raycast.Instance:IsDescendantOf(attachmentPoint);
end

--[[
	For the attachment point indicators,
	we use BillboardGuis with an outlined transparent frame inside using a UIStroke.
	First we create the UI instances and apply their properties.
	Then we define an empty variable for the animation tween which we use later,
	alongside the isClosest boolean which tells us if this attachment point is currently the closest one
	to the player's cursor.
	We use a task.defer to update the isClosest after initiation due to the BillboardGui not being parented
	as the function is being called but only after as the returned value is being set as the parent of an attachment point. (call the funcion(outside) -> create gui -> set parent(outside) -> update isClosest)
	Next we define a helper function to help us update the tween in a clean way,
	it checks if there's an active tween, which if there is it cancels,
	then in a task.defer it plays the newly set tween(which was set on the next line of the calling function).
	Then we listen to the closestAttachmentPointChanged which fires everytime the closest point to the cursor is changed,
	it checks if the current one is the closest and animates the ui based off of that utilizing the updateTween function.
	Lastly we listen for the gui.Destroying signal so we can cleanup the closestAttachmentPointChanged signal.
]]
local function createAttachmentIndicator(): BillboardGui
	local gui = Instance.new("BillboardGui");
	local frame = Instance.new("Frame");
	local stroke = Instance.new("UIStroke");

	-- setup ui stuff
	gui.Size = UDim2.fromOffset(45, 45);
	gui.AlwaysOnTop = true;
	frame.Size = UDim2.fromScale(1, 1);
	frame.AnchorPoint = Vector2.new(0.5, 0.5);
	frame.Position = UDim2.fromScale(0.5, 0.5);
	frame.Rotation = 45;
	frame.BackgroundTransparency = 1;
	stroke.Color = Color3.fromHex("#FFF");
	stroke.Thickness = 8;
	stroke.BorderStrokePosition = Enum.BorderStrokePosition.Inner;
	stroke.LineJoinMode = Enum.LineJoinMode.Miter;

	frame.Parent = gui;
	stroke.Parent = frame;

	local activeTween: Tween;
	local isClosest = false;

	-- use defer here to update closest as the billboard ui's parent
	-- is set only after this function is called
	task.defer(function()
		isClosest = closestAttachmentPoint and gui.Parent == closestAttachmentPoint.Parent;
	end);

	-- helper cleanup function to reduce bloat
	-- use defer for play to allow being able to play the tween
	-- on the next line
	local function updateTween()
		if activeTween then
			activeTween:Cancel();
		end

		task.defer(function()
			if not activeTween then return end
			activeTween:Play();
		end);
	end

	-- animate rotation and size when closest attachment point changes
	local c = closestAttachmentPointChanged:Connect(function(point)
		if not point then
			isClosest = false;
			return;
		end

		local isEqual = point.Parent == gui.Parent;
		if isClosest and not isEqual then
			isClosest = false;

			updateTween();
			activeTween = TweenService:Create(frame, TWEEN_INFO, { Rotation = 45, Size = UDim2.fromScale(1, 1) });
		elseif isEqual then
			isClosest = true;
			
			updateTween();
			activeTween = TweenService:Create(frame, TWEEN_INFO, { Rotation = 0, Size = UDim2.fromScale(1.2, 1.2) });
		end
	end);

	-- cleanup
	gui.Destroying:Once(function()
		c:Disconnect();
	end);

	return gui;
end

function retractGrapple()
	onRetracted:Fire();
	isAttached = false;
end

function deployGrapple(): nil
	local c; -- rs connection

	local char = p.Character;
	if not char or isAttached or not closestAttachmentPoint then return end

	assert(char.RightHand, "Player character is missing RightHand");
	assert(char.PrimaryPart, "Player character is missing PrimaryPart");

	local MASS = char.PrimaryPart.Mass;

	-- charPos - character position
	-- prevUnit - starting direction unit
	-- velocity - starting velocity
	-- length - length of the grapple rope
	local velocity = math.clamp(p.Character.PrimaryPart.AssemblyLinearVelocity.Y, -math.huge, TERMINAL_VELOCITY) / TERMINAL_VELOCITY;
	local charPos = char:GetPivot().Position;
	local attachmentPos = closestAttachmentPoint.Position;

	-- im aware this isn't normalized but i noticed at the end
	-- and it works with this so its not a big deal
	local prevUnit = attachmentPos - charPos;
	local length = prevUnit.Magnitude;
	local prevAngle: number?;

	-- if player is too far from the point, cancel the attachment
	if length > MAX_REACH_DISTANCE then return end
	isAttached = true;

	--[[
		Instantiate all the instances required for the grapple:
		Attachment at the attachment point to attach the rod constraint to,
		RodConstraint to keep the player at a fixed, controlled distance from the attachment point,
		grappleLine as a part to create a visual rope that the player can see,
		AlignOrientation to rotate the player's character according to the velocity,
		Animation to play the rope hold animation(use animation controller in actual codebase).
		Then, we update the character's state to Physics so external forces aren't applied on top of
		our ones, and attach the rod to the root rig attachment so it holds the player.
		Next, play the animation and connect a cleanup function to the retraction signal.
	]]

	-- init attachment part to contain the grapple attachment
	local attachment = Instance.new("Attachment", closestAttachmentPoint);

	-- init rod constraint to hold the player at a controlled distance
	local rod = Instance.new("RodConstraint");
	rod.Visible = false;
	rod.Attachment0 = attachment;
	rod.Parent = closestAttachmentPoint;

	-- visual grapple line
	local grappleLine = Instance.new("Part");
	grappleLine.Color = Color3.fromHex("#000");
	grappleLine.Anchored = true;
	grappleLine.CanCollide = false;
	grappleLine.Material = Enum.Material.SmoothPlastic;
	grappleLine.CanQuery = false;
	grappleLine.Parent = char.RightHand;
	
	-- align orientation for visuals
	local ao = Instance.new("AlignOrientation");
	ao.MaxTorque = 3e5;
	ao.MaxAngularVelocity = 50;
	ao.Responsiveness = 15;
	ao.RigidityEnabled = false;
	ao.Attachment0 = char.PrimaryPart.RootRigAttachment;
	ao.Mode = Enum.OrientationAlignmentMode.OneAttachment;
	ao.Parent = char.PrimaryPart;
	
	-- try to find animation, if not present, create new
	local anim: Animation = char.Humanoid.Animator:FindFirstChild("hold");
	if not anim then
		anim = Instance.new("Animation");
		anim.AnimationId = "rbxassetid://100287756025388";
		anim.Parent = char.Humanoid.Animator;
	end
	
	-- init state
	char.Humanoid:SetStateEnabled(Enum.HumanoidStateType.Physics, true);
	rod.Attachment1 = char.PrimaryPart.RootRigAttachment;
	
	-- play animation
	local track: AnimationTrack = char.Humanoid.Animator:LoadAnimation(anim);
	track.Looped = true;
	track.Priority = Enum.AnimationPriority.Action4;
	track:Play();
	
	-- when player retracts, recieve signal
	-- and disconnect grapple handler(cleanup)
	onRetracted:Once(function()
		char.Humanoid:SetStateEnabled(Enum.HumanoidStateType.Physics, false);
		track:Stop();
		c:Disconnect();
		rod:Destroy();
		ao:Destroy();
		grappleLine:Destroy();
	end);


	--[[
		For the physics of the grappling hook we use a RenderStepped for smoothness,
		inside we calculate the angle between the player's character and the attachment point,
		which we use to later calculate the player's character angle and vertical velocity.
		To calculate the velocity we use the momentum equation p = v * m with a 1.2 exciter factor
		and then get the velocity by multiplying the direction unit by the momentum.
		Next we update the character's AssemblyLinearVelocity directly(not using VectorForce for max control)
		and update the AlignOrientation to rotate the character to the movement direction.
		Then we update the grapple line size and the length of the rod constraint.
	]]

	-- main handler
	c = RunService.RenderStepped:Connect(function(dt)
		local fps = dt * 60;

		if not char then return end
		-- update character position variable
		charPos = char:GetPivot().Position;

		-- get the angle between the attachment point and player
		local projectedVector = CFrame.new(charPos):PointToObjectSpace(attachmentPos);
		local angle = math.abs(math.atan2(projectedVector.Y, math.sqrt(projectedVector.X ^ 2 + projectedVector.Z ^ 2)) - math.rad(90));

		-- heightFactor reverses unit when player is coming from the top down
		local heightFactor = angle > math.rad(90) and -1 or 1;

		-- define velocity variables
		local momentum = (velocity * MASS * 1.2);
		local unit = prevUnit:Lerp((attachmentPos - charPos), fps * 0.02);
		local vx = Vector3.new(unit.X * heightFactor, 0, unit.Z * heightFactor) * momentum;
		local vy = math.sin(angle) * -momentum;
		local angleDelta = if prevAngle == nil then 0 else angle - prevAngle;

		-- update values
		prevAngle = angle;
		prevUnit = unit;

		-- apply velocity and orientation
		char.PrimaryPart.AssemblyLinearVelocity = char.PrimaryPart.AssemblyLinearVelocity:Lerp(Vector3.new(vx.X, vy, vx.Z), fps * 0.05);
		ao.CFrame = CFrame.new(charPos, charPos + Vector3.new(unit.X, 0, unit.Z)) * CFrame.Angles(math.rad(90 * math.sin(angle) * math.sign(angleDelta)), 0, 0);

		-- update line
		local handPosition = char.RightHand.Position;
		local u = (attachmentPos - handPosition)
		local distFromHand = u.Magnitude;
		local handUnit = u.Unit;
		grappleLine.CFrame = CFrame.lookAt(handPosition + handUnit * distFromHand * 0.5, attachmentPos);
		grappleLine.Size = Vector3.new(0.4, 0.4, distFromHand);

		-- this is probably optional but we can control acceleration here
		velocity = math.clamp(velocity + TERMINAL_VELOCITY * fps * 0.1, 0, 1);

		-- reel in the grapple
		rod.Length = length;
		length = math.max(length - fps * 0.5, MIN_LENGTH);
	end)
end


--[[
we need to update the attachment points which are in the range
of the player, for that we use a heartbeat with a delay in which
we loop through all the possible attachment points and calculate their distance
to the player's character, comparing the distance to the player's range.
Then, we clear the attachment points that were in range the last check but aren't anymore
and add new ones that got into range.
Next, we need to obtain the closest point to the player's cursor so when they click,
the grapple will attach properly, for that we use WorldToViewportPoint which gives us a distance
of the point from the mouse, which we compare against all points in distance, giving us the closest one.
]]

local nextCheck = 0;
RunService.Heartbeat:Connect(function(dt)
	-- run the check every 0.15s
	if nextCheck > time() then return end
	nextCheck = time() + 0.15;

	local char = p.Character;
	local camera = Workspace.CurrentCamera;
	if not char or not camera then return end

	local charPos = char:GetPivot().Position;
	local pointsInDistance: { Model } = {};

	-- get all the points within the player's reach
	for _, point: Model in attachmentPointsFolder:GetChildren() do
		assert(point:IsA("Model"), `Attachment point {point.Name} is not a model`);
		local dist = (charPos - point:GetPivot().Position).Magnitude;

		if dist < MAX_REACH_DISTANCE then
			pointsInDistance[#pointsInDistance+1] = point;
		end
	end

	-- clear points out of distance since the last check
	-- if a point already active is still within distance,
	-- remove it from the array
	for point, ui in activeAttachmentUis do
		local index = table.find(pointsInDistance, point);

		if index == nil or not isAttachmentPointInSight(char, point) then
			ui:Destroy();
			activeAttachmentUis[point] = nil;
		else
			table.remove(pointsInDistance, index);
		end
	end

	-- add new active points
	for _, point in pointsInDistance do
		if not isAttachmentPointInSight(char, point) then continue end
		local ui = createAttachmentIndicator();
		ui.Parent = point;

		activeAttachmentUis[point] = ui;
	end

	-- set the point closest to the mouse
	-- by using WorldToViewportPoint, then,
	-- send signal to update all the ui's
	local iterationClosestPoint: BasePart;
	local closestDist = math.huge;
	for point in activeAttachmentUis do
		local screenPos, onScreen = camera:WorldToViewportPoint(point:GetPivot().Position);
		if not onScreen then continue end

		local distFromMouse = (Vector2.new(mouse.X, mouse.Y) - Vector2.new(screenPos.X, screenPos.Y)).Magnitude;
		if distFromMouse < closestDist and point.PrimaryPart then
			iterationClosestPoint = point.PrimaryPart;
			closestDist = distFromMouse;
		end
	end

	if closestAttachmentPoint == iterationClosestPoint then return end

	closestAttachmentPoint = iterationClosestPoint;
	closestAttachmentPointChanged:Fire(iterationClosestPoint);
end);

--[[
	listeners to player inputs,
	InputBegan handles the mouse pressing and deploying the grapple,
	InputEnded handles retracting the grapple when the player lets go of their mouse
	CharacterRemoving also retracts in case the character gets destroyed while being attached
]]

UserInputService.InputBegan:Connect(function(input, gameProcessed)
	if input.UserInputType ~= Enum.UserInputType.MouseButton1 or gameProcessed then return end
	deployGrapple();
end);

UserInputService.InputEnded:Connect(function(input)
	if input.UserInputType ~= Enum.UserInputType.MouseButton1 then return end

	retractGrapple();
end);

-- player dies, grapple detaches, we dont need a function for handling leaving
-- as this is fully client sided
p.CharacterRemoving:Connect(function(character)
	retractGrapple();
end);
