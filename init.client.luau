local Players = game:GetService("Players");
local RunService = game:GetService("RunService");
local UserInputService = game:GetService("UserInputService");
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

function Signal:Wait(...)
	local running = coroutine.running();

	self.waitingThreads[running] = true;

	self:Once(function(...)
		local args = {...};

		self.waitingThreads[running] = nil;
		task.spawn(running, unpack(args));
	end);

	return coroutine.yield();
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

local TERMINAL_VELOCITY = 100;
local MIN_LENGTH = 10;
-- studs
local MAX_REACH_DISTANCE = 500;

local p = Players.LocalPlayer;
local mouse = p:GetMouse();

local isAttached = false;
local onRetracted = Signal.new();

function deployGrapple()
	-- get target attachment point
	local attachmentPoint = mouse.Hit.Position;
	local c; -- rs connection

	local char = p.Character;
	if not char or isAttached or not mouse.Target then return end

	assert(char.RightHand, "Player character is missing RightHand");
	assert(char.PrimaryPart, "Player character is missing PrimaryPart");

	local MASS = char.PrimaryPart.Mass;

	-- charPos - character position
	-- prevUnit - starting direction unit
	-- velocity - starting velocity
	-- length - length of the grapple rope
	local velocity = math.clamp(p.Character.PrimaryPart.AssemblyLinearVelocity.Y, -math.huge, TERMINAL_VELOCITY) / TERMINAL_VELOCITY;
	local charPos = char:GetPivot().Position;

	-- im aware this isn't normalized but i noticed at the end
	-- and it works with this so its not a big deal
	local prevUnit = attachmentPoint - charPos;
	local length = prevUnit.Magnitude;
	local prevAngle: number?;

	if length > MAX_REACH_DISTANCE then return end

	isAttached = true;

	-- init attachment part to contain the grapple attachment
	local attachmentPart = Instance.new("Part");
	attachmentPart.Position = attachmentPoint;
	attachmentPart.Transparency = 1;
	attachmentPart.Anchored = true;
	local attachment = Instance.new("Attachment", attachmentPart);

	-- init rod constraint to hold the player at a controlled distance
	local rod = Instance.new("RodConstraint");
	rod.Visible = false;
	rod.Attachment0 = attachment;
	rod.Parent = attachmentPart;
	attachmentPart.Parent = workspace;

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
		attachmentPart:Destroy();
		grappleLine:Destroy();
	end);


	-- main handler
	c = RunService.RenderStepped:Connect(function(dt)
		local fps = dt * 60;

		if not char then return end
		-- update character position variable
		charPos = char:GetPivot().Position;

		-- get the angle between the attachment point and player
		local projectedVector = CFrame.new(charPos):PointToObjectSpace(attachmentPoint);
		local angle = math.abs(math.atan2(projectedVector.Y, math.sqrt(projectedVector.X ^ 2 + projectedVector.Z ^ 2)) - math.rad(90));

		-- heightFactor reverses unit when player is coming from the top down
		local heightFactor = angle > math.rad(90) and -1 or 1;
		
		-- define velocity variables
		local momentum = (velocity * MASS * 0.75);
		local unit = prevUnit:Lerp((attachmentPoint - charPos), fps * 0.009);
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
		local distFromHand = (attachmentPoint - handPosition).Magnitude;
		local handUnit = (attachmentPoint - handPosition).Unit;
		grappleLine.CFrame = CFrame.lookAt(handPosition + handUnit * distFromHand * 0.5, attachmentPoint);
		grappleLine.Size = Vector3.new(0.4, 0.4, distFromHand);

		-- this is probably optional but we can control acceleration here
		velocity = math.clamp(velocity + TERMINAL_VELOCITY * fps * 0.1, 0, 1);
	
		-- reel in the grapple
		rod.Length = length;
		length = math.max(length - fps * 0.5, MIN_LENGTH);
	end)
	
end

function retractGrapple()
	onRetracted:Fire();
	isAttached = false;
end

-- player press button -> grapple attach
UserInputService.InputBegan:Connect(function(input, gameProcessed)
	if input.UserInputType ~= Enum.UserInputType.MouseButton1 and input.UserInputType ~= Enum.UserInputType.Touch or gameProcessed then return end
	
	deployGrapple();
end);

-- player let go of button -> grapple detach
UserInputService.InputEnded:Connect(function(input)
	if input.UserInputType ~= Enum.UserInputType.MouseButton1 and input.UserInputType ~= Enum.UserInputType.Touch then return end

	retractGrapple();
end);

-- player dies, grapple detaches, we dont need a function for handling leaving
-- as this is fully client sided
p.CharacterRemoving:Connect(function(character)
	retractGrapple();
end);
