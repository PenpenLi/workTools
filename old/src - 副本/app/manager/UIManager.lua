--[[
界面管理器, 功能
1. UI加载|释放
	1. 显示界面的时候, 如果不存在, 加载界面
	2. 界面只有在需要销毁的手动调用销毁, 一般情况只隐藏
2. UI显示|隐藏
3. UI排序(强制层级)
	将UI分为5层,TopMost, Top, Normal, Bottom, BottomMost, 每一层有固定的层级范围, 每个UI都要自己定义所属的层级, 默认为Normal
	1. 显示的时候, 在本层级排序, 谁显示谁最高 
	2. 5个层,全屏层像clubMain，uimain，UILaunch 这种ui要把层级设成bottom，一般ui设成normal；tips，messageBox 设成top
	3. 显示某个大层的某个ui时，会把比该大层ZOrder更高级的ui都隐藏，而bottom一级的，也要把bottom一级的其他ui隐藏。
--]]
cc.exports.UIManager = class("UIManager")
local UI_CONFIG 	 = require("app.define.UIConfig")
local UIBase 		 = require("app.game.ui.UIBase")
local UIBaseNode  	 = class("UIBaseNode",UIBase,function() return cc.Node:create() end);
-------------------------
--层级范围
local UI_LAYER_ID 	  = config.UIConstants.UI_LAYER_ID;
local MaxLayerZOrder  = 200;		-- 最大layerorder的值，超过这个值，对所有子节点重新排序

-- 单例支持
local _instance = nil;

-- @return boolean
function UIManager:create()
	if _instance ~= nil then
		return false;
	end
	_instance = UIManager:new();
	return true;
end

function UIManager:getInstance()
	return _instance;
end

-------------------------
-- 构造函数
function UIManager:ctor()
	-- 存放ui数组
	self._gameUIs = {};
	-- 存放分层的大层layer节点,分别存放
	self._layers  = {};	
	-- 当前state里面创建UI的相关参数
	self._uiParamsLists = {}
	self._uiLists = {}
	-- 所有缓存的历史的创建UI缓存
	self._uiParamsCache = {}
	self._isNeedRestore = false

	--按层级顺序记录所有显示的UI, 初始化数量需要与UI_LAYER_ID数量一致
	self._uiLayerList = {{},{},{},{},{}};
	-- 初始化标记
	self._isHaveInit = false;
	-- 获取当前正在播放的bottomUI
	self._curBottomUI = nil;

	-- 有序存储应该显示的ui，用于对全屏弹窗覆盖下的ui进行隐藏，以减少drawcalls
	self._shoudVisibleUIs = {};

end

-- 创建5个层级，各个ui加到对应的层级上,注意这个函数不能放在ctor里面，因为那会场景还未创建成功
function UIManager:_createLayers()
	local curScene = cc.Director:getInstance():getRunningScene();
	for i = 1,5 do
		local layer = cc.Layer:create();
		curScene:addChild(layer);
		table.insert(self._layers, layer);
	end	
end

-- 初始化，只调用一次
function UIManager:init()
	if not self._isHaveInit then
		self:_createLayers();
		self._isHaveInit = true;
	end
end

function UIManager:getUI(name)
	return self._gameUIs[name];
end

-- @param state 要缓存的名称，为nil当前界面不缓存
-- @param ignores 不清除只隐藏的UI列表
local ignores = {['UIPhoneLogin']=true}
function UIManager:clear(state, destoryUnusedUI)
	-- 把上把的UI创建缓存下来，如果有需要，恢复	
	if state and state ~= "" then
		self._uiParamsCache[state] = {uiLists = self._uiLists, uiParams = self._uiParamsLists}
	end
	self._uiLists = {}
	self._uiParamsLists = {}
	
	local uicaches = {}
	for state, cache in pairs(self._uiParamsCache) do
		table.merge(uicaches, cache)
	end
	
	local function isIgnoreDestroy(name)
		if ignores and table.indexof(ignores, name) then return true end
		return uicaches[name] ~= nil		
	end 
	
	-- 隐藏所有界面
	local destroylist = {}
	for name, ui in pairs(self._gameUIs) do
		self:hideUI(ui)
		if ui:isPersistent() == false then
			table.insert(destroylist, name)
		end
	end

	-- 销毁界面
	if destoryUnusedUI == true then
		for _, name in ipairs(destroylist) do
			--登录界面的逻辑保留
			if not ignores[name] then
				self:destroy(name);
			end
		end
	end
end

-- 设置下次恢复的state要不要打开上次离开时缓存的界面
function UIManager:setNeedRestore(isNeeded)
	self._isNeedRestore = isNeeded
end

-- 进入state的时候检查使用，如果需要加存上次的缓存，返回
function UIManager:needRestore()
	return self._isNeedRestore
end

-- @param state 要加载的缓存名字，需要在上次在state exit的时候clear("")传入对应的名字
-- 在本次缓存的时候传入用来加载
function UIManager:restoreUIs(state)
	local tb = self._uiParamsCache[state]
	if #tb.uiLists == #tb.uiParams then
		for i=1,#tb.uiLists do
			self:show(tb.uiLists[i], unpack(tb.uiParams[i]))
		end
	end
end

-- 加载界面
function UIManager:_loadUI(name)
	Logger.debug("loadUI,"..name);
	Macro.assetFalse(self:getUI(name) == nil);
	
	-- 获取UI class
	local uiClass = nil;
	if nil ~= UI_CONFIG[name] then
		uiClass = require(UI_CONFIG[name]);
	else
		uiClass = require(name);
	end
	if nil == uiClass then
		error("ERROR: name or path is invalid!")
		return;
	end
	
	-- 初始化UI
	local ui = uiClass.new();
	local layerId = ui:getGradeLayerId();
	self._layers[layerId]:addChild(ui);
	ui:setName(name);
	ui:init();
	ui:setVisible(false)
	self._gameUIs[name] = ui
	
	-- 构造Mask背景
	if nil ~= ui.needBlackMask and "function" == type(ui.needBlackMask) and ui:needBlackMask() then
		self:createMaskLayer(ui);
	end
	return ui;
end

-- 创建模态层，抽出来
function UIManager:createMaskLayer(ui)
	local Mask_Name = "dlg_mask";
	local maskUI = ui:getChildByName(Mask_Name);
	local name = ui:getName();
	if nil ~= maskUI then
		Logger.error("自动创建Mask出错，UI不能有名字为dlg_mask的控件");
	else
		local mask = ccui.ImageView:create();
		mask:loadTexture("gaming/blackMask.png");
		mask:setScale9Enabled(true);
		mask:setName(Mask_Name);
		mask:setOpacity(178);

		-- 遮罩适配
		mask:setAnchorPoint(cc.p(0, 0))
		local offset = cc.p(CC_DESIGN_RESOLUTION.screen.offsetPoint().x, CC_DESIGN_RESOLUTION.screen.offsetPoint().y)
		offset.x = offset.x - CC_DESIGN_RESOLUTION.screen._safeAreaOffset_x
		mask:setPosition(offset)
		local contentSize = mask:getContentSize()
		if contentSize.width / contentSize.height > display.width / display.height then
			mask:setScale(display.height / contentSize.height)
		else
			mask:setScale(display.width / contentSize.width)
		end

		-- 设置遮罩的点击事件
		mask:setTouchEnabled(true);
		bindEventCallBack(mask, function ()
			if ui:closeWhenClickMask() == true then
				UIManager:getInstance():hide(name)
			end
		end, ccui.TouchEventType.ended);

		ui:addChild(mask,-1);
		maskUI = mask;
	end
end

-- 显示界面
function UIManager:show(name,...)
	-- 先隐藏，避免漏掉ui:onHide函数的调用,不应该正在显示，统计下看看有哪些是没有hide的
	-- Macro.assetTrue(self:getIsShowing(name));
	local param = {...};
	Logger.debug("Show UI : %s", name)
	local ui = self:getUI(name);
	
	-- 界面没有加载, 加载界面
	if nil == ui then
		ui = self:_loadUI(name);
	end
	self:_addShouldVisibleUI(ui);
	self:_addCache(name, ...)
	--为显示的ui排序
	self:_addAndShowInUILayer(ui, nil, ...);
	self:_checkShoudVisibleUIs();
	-- 设置当前bottomUI,为默认各个state下的动画根节点
	local layerId = self:getUICurentLayerId(ui);
	if layerId == UI_LAYER_ID.Bottom then
		self._curBottomUI = ui;
	end
	return ui;
end

-- 通过UI名字隐藏界面
function UIManager:hide(name)
	local ui = self:getUI(name)
	if ui == nil then
		return
	end
	
	--移除层级ui表中相应的记录
	self:_removeFromUILayer(ui)
	self:hideUI(ui)
end

-- 隐藏界面
function UIManager:hideUI(ui)
	Macro.assetFalse(self:getUI(ui:getName()) ~= nil);
	local index = table.indexof(self._shoudVisibleUIs, ui);
	if ui:isVisible() == true or index ~= false then -- 如果是由于优化drawcalls 而隐藏的，也要调一下onHide
		-- 保证隐藏韩式只被调用一次
		ui:onHide()
		ui:setVisible(false)
	end
	self:_removeShouldVisibleUI(ui);
	self:_removeCache(ui:getName());
	self:_checkShoudVisibleUIs();
end

-- 加入到应该显示的ui数组中
function UIManager:_addShouldVisibleUI(ui)
	self:_removeShouldVisibleUI(ui);
	table.insert( self._shoudVisibleUIs,ui);
end

-- 从应该显示的ui数组里面删掉ui
function UIManager:_removeShouldVisibleUI(ui)
	local index = table.indexof(self._shoudVisibleUIs,ui);
	if index ~= false then
		table.remove(self._shoudVisibleUIs, index)
	end
end

-- 检查该显示的ui是否显示
function UIManager:_checkShoudVisibleUIs()
	local len = #self._shoudVisibleUIs;
	local hideIndex = 0;
	for i = len,1,-1 do 
		local ui = self._shoudVisibleUIs[i];
		ui:setVisible(true);
		if ui:isFullScreen() then 
			hideIndex = i -1;
			break;
		end
	end
	for i = 1,hideIndex do 
		local ui = self._shoudVisibleUIs[i];
		ui:setVisible(false);
	end
end

--为显示的ui排序,默认UI都处在中间层,如果需要显示的级别与原来不一样，则重新加到新的层级节点上
function UIManager:_addAndShowInUILayer(ui, layerId, ...)
	--如果没有指定层级,则获取设置的层级id
	if not layerId then
		layerId = ui:getGradeLayerId();
	end
	Macro.assetFalse(layerId >= UI_LAYER_ID.BottomMost and layerId <= UI_LAYER_ID.TopMost);
	-- 如果传入的layerId和该ui原来所在层不一样，需要重新认父节点。
	self:_changeLayerId(ui,layerId);
	--有连续show两次的情况,如UIReconnectTips
	self:_removeFromUILayer(ui)

	--设置默认的UI层级值
	local layerValue = 0;
	--如果子节点数超过最大层级数，说明层级数小了，设个大点的值
	if #self._uiLayerList[layerId] > MaxLayerZOrder then
		MaxLayerZOrder = MaxLayerZOrder*2;
	end

	if #self._uiLayerList[layerId] > 0 then
		--根据上一个ui的层级值,计算当前ui的层级值
		local lastUi = self._uiLayerList[layerId][#self._uiLayerList[layerId]];
		layerValue = lastUi:getLocalZOrder() + 1
	end

	if layerValue >= MaxLayerZOrder then
		-- 超出当前Layer最大显示范围, 重新排序
		for i,ui in ipairs(self._uiLayerList[layerId]) do
			--重新设置当前层级所有ui的层级值
			ui:setLocalZOrder(i);
		end
	else
		--设置当前ui的索引值
		ui:setLocalZOrder(layerValue);
	end

	-- 显示UI
	-- 插入新的ui到层级ui记录
	table.insert(self._uiLayerList[layerId], ui);
	ui:setVisible(true);
	ui:onShow(...);
	return ui;
end

-- 如果某个已经存在的节点要更换大层（layerId），则需要父节点重新加一下
function UIManager:_changeLayerId(ui,layerId)
	-- 如果当前ui的父节点就是layerid 所指的layer，就不需要重新加到新父节点上
	local parent = ui:getParent();
	if not ui or not layerId or parent == nil or parent == self._layers[layerId] then
		return;
	end
	ui:retain();
	ui:removeFromParent();
	self._layers[layerId]:addChild(ui);
	ui:release();
end

--移除层级ui表中相应的记录,不管该ui是否曾经变过大层，都遍历一遍_uiLayerList数组
function UIManager:_removeFromUILayer(ui)
	-- 直接遍历数组，清理该ui
	for i,v in ipairs(self._uiLayerList) do
		local removeId = table.indexof(self._uiLayerList[i],ui);
		if removeId ~= false then
			-- 删除UI
			table.remove(self._uiLayerList[i], removeId);
		end
	end
end

-- 将数据缓存，原本的写法有问题，没有考虑zorder的问题
function UIManager:_addCache(name, ...)
	local params = {...}
	local index = table.indexof(self._uiLists, name)
	if index ~= false then
		-- 更新显示的顺序
		table.remove(self._uiLists, index)
		table.remove(self._uiParamsLists, index)
	end
	table.insert(self._uiLists, name)
	table.insert(self._uiParamsLists, params)
end

-- 如果界面在当前打开过后，并且关闭或者销毁了，从缓存中删除
function UIManager:_removeCache(name)
	local index = table.indexof(self._uiLists, name)
	if index ~= false then
		-- 更新显示的顺序
		table.remove(self._uiLists, index)
		table.remove(self._uiParamsLists, index)
	end
end

-- 获取当前ui的真实所在层,ui里面有getGradeLayerId，一般情况相等，但是在没有加入父节点时不一样。
function UIManager:getUICurentLayerId(ui)
	local layerId = 0;
	local parent  = ui:getParent();
	local index   = table.indexof(self._layers,parent);
	if index ~= false then
		layerId = index;
	end
	return layerId;
end

-- 查看界面是否显示
function UIManager:getIsShowing(name)
	local view = self:getUI(name);
	if nil ~= view then
		return view:isVisible();
	end
	return false;
end

-- 获取当前显示的bottomui
function UIManager:getCurBottomUI()
	return self._curBottomUI;
end

-- 销毁界面
function UIManager:destroy(name)
	local ui = self:getUI(name)
	if nil == ui then
		return
	end
	self:_removeShouldVisibleUI(ui);
	self:_checkShoudVisibleUIs();
	local index = table.indexof(self._shoudVisibleUIs, ui);
	if ui:isVisible() == true  or index ~= false then -- 如果是由于优化drawcalls 而隐藏的，也要调一下onHide
		-- 如果没有隐藏, 先隐藏, 保证onHide的执行
		self:hide(name)
	else
		self:_removeFromUILayer(ui)
	end
	-- 销毁界面
	ui:destroy();	
	ui:removeFromParent(false)
	self._gameUIs[name] = nil
	self:_removeCache(name)
end

-- -- remove 会删除,我只想清空

local file = io.open("../Client/src/__ClickButton.lua", "w")

if file then
	file:close()
end

-- 控件绑定回调
cc.exports.bindEventCallBack = function(register,callback,event)
	if Macro.assetTrue(register == nil,"bindEventCallBack error!") then
		return;
	end
	local registerCallBack = function(sender, eventType)
		if nil == event then
			callback(sender, eventType);
			return;
		end
		if event == eventType then

			local file = io.open("../Client/src/__ClickButton.lua", "a+")

			if file then
				file:write(os.date("%H:%M:%S", kod.util.Time.now()).." 点击按钮: "..sender:getName().."\n")
				file:close()
			end

			callback(sender);
		end
	end
	register:addTouchEventListener(registerCallBack);
end

cc.exports.bindCheckEventCallBack = function(register,callback,event)
	if Macro.assetTrue(register == nil,"bindCheckEventCallBack error!") then
		return;
	end
	if tolua.cast(register, "ccui.CheckBox") == nil then
		Macro.assetTrue(true,"Check type error") 
		return
	end

	local isSelected1 = false
	local registerCallBack = function(sender, eventType)
		if nil == event then
			callback(sender, eventType)
			return
		end

		if eventType == ccui.TouchEventType.began then
			isSelected1 = sender:isSelected()
		elseif eventType == ccui.TouchEventType.moved then
		elseif eventType == ccui.TouchEventType.ended then
			callback(sender)
		elseif eventType == ccui.TouchEventType.canceled then
			sender:setSelected(isSelected1)
		end
	end
	register:addTouchEventListener(registerCallBack);
end

-- 给任何节点注册touch响应，不仅限于button，可以是node，layer，panel，sprite。。。
-- 一般都是ended的时候响应，不用传响应事件
-- touchScale 按下时是否缩放，缩放倍数
cc.exports.bindTouchEventWithEffect = function(node, callback, touchScale)
	if Macro.assetTrue(node == nil,"bindEventCallBack error!") then
		return;
	end
	node:setTouchEnabled(true);
    local originScale = node:getScale();
    local registerCallBack = function(sender, eventType)
		if eventType == ccui.TouchEventType.began then
			node:setScale(touchScale or originScale);
		elseif eventType == ccui.TouchEventType.moved then
		else    -- 其他情况，恢复按钮原始状态
			node:setScale(originScale);
		end
        -- 回调
		if eventType == ccui.TouchEventType.ended then

			local file = io.open("../Client/src/__ClickButton.lua", "a+")
			file:write(os.date("%H:%M:%S", kod.util.Time.now()).." 点击按钮: "..sender:getName().."\n")
			file:close()
			
			callback(sender, eventType);
		end
	end

	node:addTouchEventListener(registerCallBack);
end


-- 通过名字查找子控件
cc.exports.seekNodeByName = function(view,name, property)
	return tolua.cast(ccui.Helper:seekNodeByName(view, name), property);
end

-- 绑定node及其子节点到target，target不传的话返回一个表。
-- 优点是可以直接访问节点，target.name;缺点是同名的节点会被覆盖
cc.exports.bindNodeToTarget = function(view, target)
	local tt = target or {};
	if view == nil or view:getName() == nil or view:getName() == "" then
		return tt;
	end
	tt[view:getName()] = view;
	local children = view:getChildren();
	for i = 1, #children do
		bindNodeToTarget(children[i],tt);
	end
	return tt;
end

-- 绑定node及其子节点到target，target不传的话返回一个表。
-- 优点是同名的节点不会被覆盖；缺点是访问时需要知道层级关系target.parentName.childName
cc.exports.bindNodeToTarget2 = function(view, target)
	local tt = target or {};
	if view == nil or view:getName() == nil or view:getName() == "" then
		return tt;
	end
	tt[view:getName()] = view;
	for i = 1, #children do
		bindNodeToTarget2(children[i],tt[view:getName()]);
	end
	return tt;
end

