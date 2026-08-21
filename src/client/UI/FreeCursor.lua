--!nonstrict
--[[
	FreeCursor — hand the mouse back to the player, and take it away again.

		FreeCursor.take(restore)      -- opening a screen with things to click
		FreeCursor.giveBack(restore)  -- closing it

	`restore` is the CALLER'S OWN table. This module owns the rules; the caller
	owns the saved values, because these screens nest — the settings panel opens
	over the pause menu, which can open over a live round — and a single shared
	slot would have the inner screen hand back the outer screen's camera.

	── WHY IT IS NOT JUST CameraMode ───────────────────────────────────────────
	Three screens each had their own copy of this and all three were wrong the
	same way: they set `CameraMode = Classic` and stopped.

	That is only half of it. CameraController writes
	`CameraMaxZoomDistance = 0.5` for any survivor who is not Dead or
	Spectating, and Roblox forces FIRST PERSON — and therefore a pinned cursor —
	whenever the camera is zoomed that far in, whatever the mode says.
	ViewmodelController already tested the pair together and said so in a
	comment: `CameraMode == Classic and CameraMaxZoomDistance > 1`.

	It hid because the main menu usually opens when the player is Dead or
	Spectating, where the zoom is already 128. The two places it did not hide:

	  * the PAUSE menu, which opens mid-round while alive — press pause, and the
	    cursor stays welded to the middle of the screen with Resume unclickable;
	  * a TEAM WIPE, which leaves everyone Incapacitated rather than Dead, so the
	    results screen came up over a 0.5 zoom and a desktop player could not
	    click the screen the game had just put them on.

	── ORDERING ────────────────────────────────────────────────────────────────
	Roblox clamps the two zoom properties against each other, so the order of the
	writes is load-bearing in both directions and is the reason this is a
	function rather than four lines copied a fourth time.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Registry = require(Shared.Util.Registry)

local player = Players.LocalPlayer

--[[ Far enough that Roblox stops forcing first person, close enough that this
     stays a cursor release rather than a spectator camera. CameraController
     uses 128 for a dead player who has nothing to do but watch the team; there
     is no reason to let someone pull that far back behind a scoreboard. ]]
local FREE_ZOOM = 12

local FreeCursor = {}

export type Restore = {
	cameraMode: any,
	cameraZoom: any,
	cameraMinZoom: any,
	mouseIcon: any,
}

--[[
	Which screens are currently holding the cursor, and how many.

	── WHY A COUNT AND NOT A BOOLEAN ───────────────────────────────────────────
	These screens nest. Settings opens over the pause menu, the pause menu opens
	over a live round, a vote opens over the main menu. A boolean would let the
	INNER screen closing declare the cursor free for the outer one that is still
	up, which is precisely the bug this exists to stop.

	── WHY ANYTHING OUTSIDE THIS FILE NEEDS TO KNOW ────────────────────────────
	CameraController re-asserts LockFirstPerson and a 0.5 zoom every time the
	player's state attribute changes, and it does that whether or not a screen
	with buttons on it is up. So the cursor was being taken back UNDERNEATH an
	open screen by anything that changed state while it was open:

	  * a team wipe leaves everyone Incapacitated, the results screen opens, and
	    the round then resets the state — re-pinning the mouse over the very
	    screen the game just put the player on, which is the original report;
	  * being downed, revived or respawned while the pause menu is open does the
	    same thing to Resume;
	  * and closing an INNER screen did it too, because giveBack asks
	    CameraController to re-assert — so pause, open settings, come back, and
	    the pause menu you are still looking at has a pinned cursor.

	All three are one fact: CameraController owns those properties and had no way
	to know it was being asked to fight a screen. Now it can ask.
]]
local holders: { [any]: boolean } = {}
local holderCount = 0

--[[ Whether ANY screen currently holds the cursor. CameraController stands down
     while this is true rather than writing properties that would be wrong the
     moment it wrote them; the last giveBack asks it for a fresh answer. ]]
function FreeCursor.isHeld(): boolean
	return holderCount > 0
end

function FreeCursor.take(restore: Restore)
	--[[ Only the FIRST take records anything. A screen opening over another
	     already-free screen would otherwise save the freed values as the ones to
	     hand back, and closing it would leave the camera unlocked for the round. ]]
	if restore.cameraMode == nil then
		restore.cameraMode = player.CameraMode
		restore.cameraZoom = player.CameraMaxZoomDistance
		restore.cameraMinZoom = player.CameraMinZoomDistance
		restore.mouseIcon = UserInputService.MouseIconEnabled
	end
	--[[ Keyed on the caller's own table, so a screen that takes twice without
	     giving back — which happens, since take is called from refresh functions
	     that run on every visibility change — counts once and is released once. ]]
	if not holders[restore] then
		holders[restore] = true
		holderCount += 1
	end

	player.CameraMode = Enum.CameraMode.Classic
	-- Max first: the min is compared against it, and setting a min of 4 while the
	-- max is still 0.5 is rejected.
	player.CameraMaxZoomDistance = FREE_ZOOM
	player.CameraMinZoomDistance = math.min(FREE_ZOOM, 4)
	UserInputService.MouseIconEnabled = true
end

--[[
	── WHY THIS ASKS RATHER THAN REPLAYS ───────────────────────────────────────
	The saved values are a snapshot of what was true when the screen OPENED, and
	the answer can change while it is open. The main menu is the case that bit:
	it opens over the lobby, where the player has no body and CameraController
	has set Classic with a zoom of 128 so they can watch; the round then starts,
	CameraController puts them in first person, and the menu closes and restores
	its snapshot over the top. A live survivor, parked four studs behind
	themselves with a free mouse, for the whole round — a giant weapon across the
	middle of the screen, no crosshair worth aiming, and a cursor floating over
	a game that is trying to be a shooter.

	CameraController owns those three properties. It is asked to re-assert them
	and the snapshot is only replayed when it is not there to ask, which is a
	load-order failure rather than a normal frame.
]]
function FreeCursor.giveBack(restore: Restore)
	--[[ RELEASED FIRST, and the order is load-bearing. Everything below either
	     asks CameraController for the camera it wants or replays a snapshot, and
	     CameraController now declines to touch the camera while a screen is
	     holding it — so releasing after the refresh would make the refresh a
	     no-op and leave the cursor free for the rest of the round. ]]
	if holders[restore] then
		holders[restore] = nil
		holderCount -= 1
	end

	if restore.mouseIcon ~= nil then
		UserInputService.MouseIconEnabled = restore.mouseIcon
	end

	local camera = Registry.find("CameraController")
	if camera and typeof(camera.refreshCameraMode) == "function" then
		camera:refreshCameraMode()
	else
		if restore.cameraMinZoom ~= nil and restore.cameraZoom ~= nil then
			-- Min first on the way back, the mirror of the reason above: the max
			-- being restored is the smaller of the two.
			player.CameraMinZoomDistance = restore.cameraMinZoom
			player.CameraMaxZoomDistance = restore.cameraZoom
		end
		if restore.cameraMode ~= nil then
			player.CameraMode = restore.cameraMode
		end
	end

	restore.cameraMode = nil
	restore.cameraZoom = nil
	restore.cameraMinZoom = nil
	restore.mouseIcon = nil
end

--[[ Whether the cursor is currently free, by the same test ViewmodelController
     uses. For a caller that needs to know rather than to change it. ]]
function FreeCursor.isFree(): boolean
	return player.CameraMode == Enum.CameraMode.Classic and player.CameraMaxZoomDistance > 1
end

return FreeCursor
