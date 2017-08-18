# Proxy object for forwarding method calls to the node object inside the page.

class Poltergeist.Node
  @DELEGATES = ['allText', 'visibleText', 'getAttribute', 'getAttributes', 'value', 'set', 'setAttribute', 'isObsolete',
                'removeAttribute', 'isMultiple', 'select', 'tagName', 'find',
                'isVisible', 'isInViewport', 'position', 'trigger', 'parentId', 'parentIds', 'mouseEventTest',
                'scrollIntoView', 'isDOMEqual', 'isDisabled', 'deleteText', 'containsSelection',
                'path', 'getProperty']

  for name in @DELEGATES
    do (name) =>
      Node.prototype[name] = (args...) ->
        @page.nodeCall(@id, name, args)

  constructor: (@page, @id) ->

  parent: ->
    new Poltergeist.Node(@page, this.parentId())

  mouseEventPosition: ->
    viewport = @page.viewportSize()

    image = await @_getAreaImage()
    pos = if image
      p = await image.position()
      area_offset = await @_getAreaOffsetRect()
      if area_offset
        p.left = p.left + area_offset.x
        p.right = p.left + area_offset.width
        p.top = p.top + area_offset.y
        p.bottom = p.top + area_offset.height
      p
    else
      await this.position()

    middle = (start, end, size) ->
      Math.round(start + ((Math.min(end, size) - start) / 2))

    {
      x: middle(pos.left, pos.right,  viewport.width),
      y: middle(pos.top,  pos.bottom, viewport.height)
    }

  mouseEvent: (name) ->
    area_image = await @_getAreaImage()
    if area_image
      await area_image.scrollIntoView()
    else
      await @scrollIntoView()
    pos = await @mouseEventPosition()
    test = await @mouseEventTest(pos.x, pos.y)
    if test.status == 'success'
      if name == 'rightclick'
        @page.mouseEvent('click', pos.x, pos.y, 'right')
        this.trigger('contextmenu')
      else
        @page.mouseEvent(name, pos.x, pos.y)
      pos
    else
      Promise.reject(new Poltergeist.MouseEventFailed(name, test.selector, pos))

  dragTo: (other) ->
    await @scrollIntoView()
    Promise.all([@mouseEventPosition(),other.mouseEventPosition()]).then (positions)=>
      @page.mouseEvent('mousedown', positions[0].x, positions[0].y).then =>
        return new Promise((resolve)->
           setTimeout(resolve, 100)
        ).then =>
          @page.mouseEvent('mouseup', positions[1].x, positions[1].y).then

  dragBy: (x, y) ->
    await @scrollIntoView()
    position = await @mouseEventPosition()
    final_pos =
      x: position.x + x
      y: position.y + y

    @page.mouseEvent('mousedown', position.x, position.y).then =>
      @page.mouseEvent('mouseup', final_pos.x, final_pos.y)

  isEqual: (other) ->
    @page == other.page && this.isDOMEqual(other.id)

  _getAreaOffsetRect: ->
    # get the offset of the center of selected area
    attrs = await @getAttributes('shape', 'coords')
    shape = attrs['shape'].toLowerCase();
    coords = (parseInt(coord,10) for coord in attrs['coords'].split(','))

    rect = switch shape
      when 'rect', 'rectangle'
        #coords.length == 4
        [x,y] = coords
        { x: x, y: y, width: coords[2] - x, height: coords[3] - y }
      when 'circ', 'circle'
        # coords.length == 3
        [centerX, centerY, radius] = coords
        { x: centerX - radius, y: centerY - radius, width: 2 * radius, height: 2 * radius }
      when 'poly', 'polygon'
        # coords.length > 2
        # This isn't correct for highly concave polygons but is probably good enough for
        # use in a testing tool
        xs = (coords[i] for i in [0...coords.length] by 2)
        ys = (coords[i] for i in [1...coords.length] by 2)
        minX = Math.min xs...
        maxX = Math.max xs...
        minY = Math.min ys...
        maxY = Math.max ys...
        { x: minX, y: minY, width: maxX-minX, height: maxY-minY }

  _getAreaImage: ->
    @tagName().then (tn)=>
      if tn.toLowerCase() == 'area'
        map = @parent()
        @parent().then (map)=>
          map.tagName().then (map_tn)=>
            if map_tn.toLowerCase() != 'map'
              throw new Error('the area is not within a map')

            map.getAttribute('name').then (mapName)=>
              if not mapName?
                throw new Error ("area's parent map must have a name")
              mapName = '#' + mapName.toLowerCase()

              image_node_id =
              @page.find('css', "img[usemap='#{mapName}']").then (els)=>
                image_node_id=els[0]
                if not image_node_id?
                  throw new Error ("no image matches the map")

                @page.get(image_node_id)
