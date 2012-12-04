###
# Copyright (C) 2012 jareiko / http://www.jareiko.net/
###

define [
  'zepto'
  'backbone-full'
  'THREE'
  'util/util'
  'cs!client/client'
  'cs!client/misc'
  'client/car'
  'game/game'
  'game/track'
  'cs!util/quiver'
], ($, Backbone, THREE, util, clientClient, clientMisc, clientCar, gameGame, gameTrack, quiver) ->
  KEYCODE = util.KEYCODE
  Vec2 = THREE.Vector2
  Vec3 = THREE.Vector3

  class TrackModel
    constructor: (@track) ->
      _.extend @, Backbone.Events
    markModified: ->
      @trigger 'change'

  InspectorController = (selected, track) ->
    $inspector = $('#editor-inspector')
    $inspectorAttribs = $inspector.find('.attrib')

    attrib = (selector) ->
      $el = $inspector.find selector
      $root: $el
      $content: $el.find '.content'

    selType         = attrib '#sel-type'
    selTitle        = attrib '#title'
    selDispRadius   = attrib '#disp-radius'
    selDispHardness = attrib '#disp-hardness'
    selDispStrength = attrib '#disp-strength'
    selSurfRadius   = attrib '#surf-radius'
    selSurfHardness = attrib '#surf-hardness'
    selSurfStrength = attrib '#surf-strength'

    checkpointSlider = (slider, eachSel) ->
      $content = slider.$content
      $content.on 'change', ->
        val = parseFloat $content.val()
        updated = no
        for sel in selected when sel.type is 'checkpoint'
          eachSel sel, val
          updated = yes
        quiver.push track.track.config.course.checkpoints if updated
        track.markModified()

    checkpointSlider selDispRadius,   (sel, val) -> sel.object.disp.radius   = val
    checkpointSlider selDispHardness, (sel, val) -> sel.object.disp.hardness = val
    checkpointSlider selDispStrength, (sel, val) -> sel.object.disp.strength = val
    checkpointSlider selSurfRadius,   (sel, val) -> sel.object.surf.radius   = val
    checkpointSlider selSurfHardness, (sel, val) -> sel.object.surf.hardness = val
    checkpointSlider selSurfStrength, (sel, val) -> sel.object.surf.strength = val

    checkpointSliderSet = (slider, val) ->
      slider.$content.val val
      slider.$root.addClass 'visible'

    @onSelectionChange = ->
      # Hide all controls, then re-enable relevant ones.
      $inspectorAttribs.removeClass 'visible'

      selType.$content.text switch selected.length
        when 0 then 'track'
        when 1 then selected[0].type
        else '[multiple]'
      selType.$root.addClass 'visible'

      if selected.length is 0
        # If no selection, we inspect the track properties.
        selTitle.$content.text track.track.name
        selTitle.$root.addClass 'visible'
      else for sel in selected
        switch sel.type
          when 'checkpoint'
            checkpointSliderSet selDispRadius,   sel.object.disp.radius
            checkpointSliderSet selDispHardness, sel.object.disp.hardness
            checkpointSliderSet selDispStrength, sel.object.disp.strength
            checkpointSliderSet selSurfRadius,   sel.object.surf.radius
            checkpointSliderSet selSurfHardness, sel.object.surf.hardness
            checkpointSliderSet selSurfStrength, sel.object.surf.strength
      return

    @onSelectionChange()

  run: ->
    $container = $(window)
    $statusbar = $('#editor-statusbar')
    $view3d = $('#view3d')
    $status = $statusbar.find('#status')

    setStatus = (msg) -> $status.text msg
    setStatus 'OK'

    game = new gameGame.Game()
    client = new clientClient.TriggerClient $view3d[0], game

    # HACK: Pack the terrain config directly into the track.
    # These are stripped out again during save. FIXME.
    TRIGGER.TRACK.config.envScenery = TRIGGER.TRACK.env.scenery
    TRIGGER.TRACK.config.terrain = TRIGGER.TRACK.env.terrain

    track = null
    game.setTrackConfig TRIGGER.TRACK.config, (err, theTrack) ->
      track = theTrack
      client.addEditorCheckpoints track

    class MockVehicle
      constructor: (@cfg) ->

    startPos = new THREE.Object3D()
    startPosConfig = TRIGGER.TRACK.config.course.startposition
    startPos.updateFromConfig = ->
      startPos.position.set.apply startPos.position, startPosConfig.pos
      startPos.rotation.set.apply startPos.rotation, startPosConfig.rot
    startPos.updateFromConfig()
    client.scene.add startPos

    carConfig = TRIGGER.TRACK.env.cars[0].config
    mockVehicle = new MockVehicle carConfig
    mockVehicle.body =
      interp:
        pos: new Vec3(0,0,0)
        ori: (new THREE.Quaternion(1,1,1,1)).normalize()
    @renderCar = new clientCar.RenderCar startPos, mockVehicle, null
    @renderCar.update()

    layout = ->
      #[$statusbar, $view3d].forEach (panel) ->
        #panel.css 'position', 'absolute'
        #panel.width $container.width()
      statusbar_HEIGHT = $statusbar.height()
      #$statusbar.height statusbar_HEIGHT
      $view3d.height $container.height() - statusbar_HEIGHT
      $view3d.css 'top', statusbar_HEIGHT
      client.setSize $view3d.width(), $view3d.height()
      return

    layout()
    $container.on 'resize', ->
      layout()

    client.camera.eulerOrder = 'ZYX'
    camPos = client.camera.position.copy startPos.position
    camPos.z += 50
    camPos.y -= 30
    camAng = client.camera.rotation.set 0.6, 0, 0
    camVel = new Vec3
    camVelTarget = new Vec3
    camAngVel = new Vec3
    camAngVelTarget = new Vec3

    selected = []

    trackModel = new TrackModel TRIGGER.TRACK
    inspectorController = new InspectorController selected, trackModel

    doSave = _.debounce ->
      formData = new FormData()
      formData.append 'name', track.name
      # HACK: Strip out the data we packed in earlier.
      stripped = _.omit track.config, ['envScenery', 'terrain']
      formData.append 'config', JSON.stringify stripped
      request = new XMLHttpRequest()
      url = '/track/' + TRIGGER.TRACK.id + '/json/save'
      request.open 'POST', url, true
      request.onload = ->
        if request.status is 200
          setStatus 'OK'
        else
          setStatus request.status
      request.onerror = ->
        setStatus 'ERROR'
      request.send formData
    , 1000

    requestSave = ->
      setStatus 'Saving...'
      doSave()

    trackModel.on 'change', requestSave

    requestId = 0

    objSpinVel = 0
    lastTime = 0
    tmpVec3 = new THREE.Vector3
    update = (time) ->
      requestId = 0
      if lastTime
        delta = Math.min 0.1, (time - lastTime) * 0.001
      else
        delta = 0.001

      terrainHeight = 0
      if track?
        terrainHeight = (track.terrain.getContactRayZ camPos.x, camPos.y).surfacePos.z
      SPEED = 30 + 0.8 * Math.max 0, camPos.z - terrainHeight
      ANG_SPEED = 2
      VISCOSITY = 20
      camVelTarget.set 0, 0, 0
      camAngVelTarget.set 0, 0, 0
      keyDown = client.keyDown
      if keyDown[KEYCODE.SHIFT] then SPEED *= 3
      if keyDown[KEYCODE.RIGHT] then camVelTarget.x += SPEED
      if keyDown[KEYCODE.LEFT] then camVelTarget.x -= SPEED
      if keyDown[KEYCODE.UP] then camVelTarget.y += SPEED
      if keyDown[KEYCODE.DOWN] then camVelTarget.y -= SPEED
      if keyDown[KEYCODE.R] then camVelTarget.z += SPEED
      if keyDown[KEYCODE.F] then camVelTarget.z -= SPEED
      if keyDown[KEYCODE.W] then camAngVelTarget.x += ANG_SPEED
      if keyDown[KEYCODE.S] then camAngVelTarget.x -= ANG_SPEED
      if keyDown[KEYCODE.A] then camAngVelTarget.z += ANG_SPEED
      if keyDown[KEYCODE.D] then camAngVelTarget.z -= ANG_SPEED

      if keyDown[188]
        objSpinVel += 5 * delta
      else if keyDown[190]
        objSpinVel -= 5 * delta
      else
        objSpinVel = 0

      if objSpinVel isnt 0
        updateLayers = {}
        updateStartPos = no
        for sel in selected
          rot = sel.object.rot
          continue unless rot?
          rot[2] += objSpinVel * delta
          rot[2] -= Math.floor(rot[2] / Math.PI / 2) * Math.PI * 2
          switch sel.type
            when 'startpos'
              startPos.updateFromConfig()
              updateStartPos = yes
            when 'scenery'
              updateLayers[sel.layer] = yes
        for layer of updateLayers
          track.scenery.invalidateLayer layer
        requestSave() if updateLayers or updateStartPos

      camVelTarget.set(
          camVelTarget.x * Math.cos(camAng.z) - camVelTarget.y * Math.sin(camAng.z),
          camVelTarget.x * Math.sin(camAng.z) + camVelTarget.y * Math.cos(camAng.z),
          camVelTarget.z)

      mult = 1 / (1 + delta * VISCOSITY)
      camVel.x = camVelTarget.x + (camVel.x - camVelTarget.x) * mult
      camVel.y = camVelTarget.y + (camVel.y - camVelTarget.y) * mult
      camVel.z = camVelTarget.z + (camVel.z - camVelTarget.z) * mult
      camAngVel.x = camAngVelTarget.x + (camAngVel.x - camAngVelTarget.x) * mult
      camAngVel.y = camAngVelTarget.y + (camAngVel.y - camAngVelTarget.y) * mult
      camAngVel.z = camAngVelTarget.z + (camAngVel.z - camAngVelTarget.z) * mult

      camPos.addSelf tmpVec3.copy(camVel).multiplyScalar delta
      if track?
        terrainHeight = (track.terrain.getContactRayZ camPos.x, camPos.y).surfacePos.z
        camPos.z = Math.max camPos.z, terrainHeight + 1

      camAng.addSelf tmpVec3.copy(camAngVel).multiplyScalar delta
      camAng.x = Math.max 0, Math.min 2, camAng.x

      client.update delta
      client.render()

      if camVel.length() > 0.1 or
         camAngVel.length() > 0.01 or
         objSpinVel isnt 0 or
         true
        lastTime = time
        requestAnim()
      else
        lastTime = 0
      return

    requestAnim = ->
      unless requestId then requestId = requestAnimationFrame update

    setInterval requestAnim, 1000

    $(document).on 'keyup', (event) -> client.onKeyUp event
    $(document).on 'keydown', (event) -> client.onKeyDown event
    client.on 'keydown', (event) ->
      if track?
        checkpoints = track.config.course.checkpoints
        moveAmt = 1
        if client.keyDown[KEYCODE.SHIFT] then moveAmt *= 5
        switch event.keyCode
          when KEYCODE['P']
            for sel in selected when sel.type is 'scenery'
              pos = sel.object.pos
              rot = sel.object.rot
              layer = track.scenery.getLayer sel.layer
              layer.config.density.add.push
                pos: [pos[0], pos[1], pos[2]]
                rot: [rot[0], rot[1], rot[2]]
                scale: sel.object.scale
              sel.mesh.position.z = pos[2] += 5
              track.scenery.invalidateLayer sel.layer
          when KEYCODE.BACKSPACE
            remaining = []
            for sel in selected
              if sel.type is 'scenery'
                layer = track.scenery.getLayer sel.layer
              else
                remaining.push sel
            selected = remaining
      requestAnim()
      return

    clearSelection = ->
      for sel in selected
        client.scene.remove sel.mesh
      selected.length = 0
      return

    addSelection = (sel) ->
      sel.mesh = clientMisc.selectionMesh()
      pos = sel.object.pos
      radius = 2
      switch sel.type
        when 'checkpoint'
          radius = 4
      sel.mesh.scale.multiplyScalar radius
      sel.mesh.position.set pos[0], pos[1], pos[2]
      client.scene.add sel.mesh
      selected.push sel
      return

    inSelection = (query) ->
      for sel in selected
        return true if sel.object is query.object
      false

    # TODO: encapsulate mouse event handling
    mouseX = 0
    mouseY = 0
    mouseDistance = 0
    buttons = 0
    isSecondClick = no  # We only allow dragging on second click to prevent mistakes.

    $view3d.on 'mousedown', (event) ->
      buttons |= Math.pow(2, event.button)
      mouseX = event.layerX
      mouseY = event.layerY
      isect = client.findObject mouseX, mouseY
      isect.sort (a, b) -> a.distance > b.distance
      firstHit = isect[0]
      #clearSelection()
      underCursor = null
      if firstHit?
        mouseDistance = firstHit.distance
        underCursor = firstHit unless firstHit.type is 'terrain'
      else
        mouseDistance = 0
      isSecondClick = if underCursor then inSelection(underCursor) else no
      clearSelection() unless event.shiftKey or isSecondClick
      addSelection underCursor if underCursor unless isSecondClick
      requestAnim()
      inspectorController.onSelectionChange()
      return

    $view3d.on 'mouseup', (event) ->
      buttons &= ~Math.pow(2, event.button)
      return

    $view3d.on 'mousemove', (event) ->
      if buttons & 3 and mouseDistance > 0
        right = client.camera.matrixWorld.getColumnX()
        forward = (new Vec3).cross client.camera.up, right
        motionX = event.layerX - mouseX
        motionY = event.layerY - mouseY
        mouseX = event.layerX
        mouseY = event.layerY
        eye = client.viewToEyeRel new Vec2 motionX, motionY
        eye.multiplyScalar mouseDistance
        tmp = new Vec3
        motion = new Vec3
        tmp.copy(right).multiplyScalar eye.x
        motion.addSelf tmp
        if event.shiftKey
          motion.z = eye.y
        else
          tmp.copy(forward).multiplyScalar eye.y
          motion.addSelf tmp
        if buttons & 1 and selected.length > 0 and isSecondClick
          updateStartPos = no
          updateCheckpoints = no
          updateLayers = {}

          for sel in selected
            pos = sel.object.pos
            pos[0] += motion.x
            pos[1] += motion.y
            pos[2] += motion.z
            switch sel.type
              when 'startpos'
                updateStartPos = yes
                startPos.updateFromConfig()
              when 'checkpoint'
                updateCheckpoints = yes
              when 'scenery'
                updateLayers[sel.layer] = yes
                tmp.set pos[0], pos[1], -Infinity
                contact = track.terrain.getContact tmp
                pos[2] = contact.surfacePos.z
            sel.mesh.position.set pos[0], pos[1], pos[2]

          courseConfig = track.config.course
          quiver.push courseConfig.checkpoints if updateCheckpoints
          for layer of updateLayers
            track.scenery.invalidateLayer layer
          requestSave() if updateCheckpoints or updateLayers or updateStartPos
        else
          if event.shiftKey or buttons & 2
            camAngVel.z += motionX * 0.1
            camAngVel.x += motionY * 0.1
          else
            motion.multiplyScalar 10
            camVel.subSelf motion
        requestAnim()
      return

    scroll = (scrollY) ->
      forward = client.camera.matrixWorld.getColumnZ()
      tmp = new Vec3
      tmp.copy(forward).multiplyScalar scrollY * -2
      camVel.addSelf tmp
      #client.camera.rotation.z += event.wheelDeltaX * 0.01
      event.preventDefault()
      return

    $view3d.on 'mousewheel', (event) ->
      scroll event.wheelDeltaY or event.deltaY

    return
