unit GW.MGW.Modules;

interface

function MGWModule(const Name: string): string;

implementation

{$TEXTBLOCK LF}

function MGWModule(const Name: string): string;
begin
  Result := '';
  if Name = 'class' then
    Result := '''
      --[[
      Copyright (c) 2010–2015 André Leiradella
      
      Permission is hereby granted, free of charge, to any person obtaining a copy
      of this software and associated documentation files (the "Software"), to deal
      in the Software without restriction, including without limitation the rights
      to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
      copies of the Software, and to permit persons to whom the Software is
      furnished to do so, subject to the following conditions:
      
      * The above copyright notice and this permission notice shall be included in
        all copies or substantial portions of the Software.
      
      THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
      IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
      FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
      AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
      LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
      OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
      SOFTWARE. 
      ]]
      
      local M = {}
      
      local pairs = pairs
      local type = type
      local sub = string.sub
      local unpack = table.unpack
      local setmetatable = setmetatable
      local _G = _G
      local methods = {}
      setmetatable( methods, { __mode = 'k' } )
      
      function M.new( ... )
        local arg = { ... }
        -- create an empty class
        local new_class = {}
        
        -- copy all methods from the super classes
        for index = 1, #arg do
          for name, method in pairs( arg[ index ] ) do
            if not new_class[ name ] then
              new_class[ name ] = method
            end
          end
        end
        
        -- insert an additional method to check the class of the instance
        new_class.instanceOf = function( self, klass )
          if klass == new_class then
            return true
          end
          
          for index = 1, #arg do
            if arg[ index ].instanceOf( self, klass ) then
              return true
            end
          end
          
          return false
        end
        
        -- insert an additional method to return the class of an instance
        new_class.getClass = function()
          return new_class
        end
        
        -- insert an additional method to return the class name of an instance (only works if the class is accessible from the global space)
        new_class.getClassName = function()
          local function find( space, name, visited )
            if visited[ space ] then
              return nil
            end
            
            visited[ space ] = true
            
            for key, value in pairs( space ) do
              if value == new_class then
                return name .. '.' .. key
              end
              
              if type( value ) == 'table' then
                local found = find( value, name .. '.' .. key, visited )
                
                if found ~= nil then
                  return found
                end
              end
            end
            
            return nil
          end
          
          local found = find( _G, '_G', {} )
          
          if found then
            return sub( found, 4, -1 )
          end
          
          return nil
        end
        
        -- the function to index mathods of the class
        local index = function( instance, key )
          -- check the methods cache
          local method = methods[ instance ][ key ]
          
          if not method then
            -- not found, create the method and put it into the cache
            method = function( ... )
              return new_class[ key ]( instance, ... )
            end
            
            methods[ instance ][ key ] = method
          end
          
          return method
        end
        
        -- the metatable of the instances
        local self_meta = { __index = index }
        
        -- turn the self table into an instance of the class
        new_class.makeInstance = function( self )
          -- create the methods cache
          methods[ self ] = {}
          -- set the metatable and return the instance
          return setmetatable( self, self_meta )
        end
      
        -- create a __call metamethod that creates a new instance of the class
        local class_meta = {}
        
        class_meta.__call = function( ... )
          local arg = { ... }
          
          -- create an empty instance
          local self = {}
          new_class.makeInstance( self )
          
          -- the first argument is the class, shift left all other arguments
          for i = 2, #arg do
            arg[ i - 1 ] = arg[ i ]
          end
          
          arg[ #arg ] = nil
          
          -- call the new method to initialize the instance
          if new_class.new then
            new_class.new( self, unpack( arg ) )
          end
          
          -- return the newly created instance
          return self
        end
      
        -- set the metatable of the class and return it
        return setmetatable( new_class, class_meta )
      end
      
      function M.instanceOf( instance, class )
        return type( instance ) == 'table' and instance.instanceOf and instance.instanceOf( class )
      end
      
      function M.abstract()
        local proxy = {}
        
        proxy.__call =  function( proxy, self )
          local klass = self:getClass()
          local methodName = '?'
          
          for name, method in pairs( klass ) do
            if method == proxy then
              methodName = name
              break
            end
          end
          
          error( 'The method ' .. ( self:getClassName() or '?' ) .. '.' .. methodName .. ' is abstract, please implement it.' )
        end
        
        setmetatable( proxy, proxy )
        return proxy
      end
      
      return M
      
      ''';
  if Name = 'classes' then
    Result := '''
      local M = {}
      
      M.tshiftstate = 0
      M.ssleft = 0
      M.tacenter = 0
      
      return M
      
      ''';
  if Name = 'controls' then
    Result := '''
      local M = {}
      
      M.tmousebutton = 0
      M.mbleft = 0
      M.crhelp = 0
      M.crhandpoint = 0
      M.crdefault = 0
      
      return M
      
      ''';
  if Name = 'dialogs' then
    Result := '''
      local M = {}
      return M
      
      ''';
  if Name = 'extctrls' then
    Result := '''
      local M = {}
      
      M.timage = system.newimage
      M.ttimer = system.newtimer
      
      return M
      
      ''';
  if Name = 'fmod' then
    Result := '''
      local fmodtypes = system.loadunit 'fmodtypes'
      
      local M = {}
      
      M.fsound_sample_free = function()
      end
      
      M.fsound_close = function()
      end
      
      M.fsound_playsound = function( channel, pfs )
        system.playsound( pfs, channel )
      end
      
      M.fsound_stopsound = function( channel )
        system.stopsounds( channel or fmodtypes.fsound_free )
      end
      
      M.fsound_setsfxmastervolume = function( vol )
      end
      
      return M
      
      ''';
  if Name = 'fmodtypes' then
    Result := '''
      local M = {}
      
      M.pfsoundsample = system.newsound
      M.fsound_free = -1
      
      return M
      
      ''';
  if Name = 'forms' then
    Result := '''
      local class = system.loadunit 'class'
      local graphics = system.loadunit 'graphics'
      local stdctrls = system.loadunit 'stdctrls'
      
      local M = {}
      
      M.tform = class.new()
      
      function M.tform:new()
        --self.popupmenu = M.tform()
        self.font = graphics.tfont()
        self.horzscrollbar = stdctrls.tscrollbar()
        self.vertscrollbar = stdctrls.tscrollbar()
      end
      
      function M.tform:show()
      end
      
      function M.tform:onactivate()
      end
      
      function M.tform:onclose()
      end
      
      function M.tform:oncreate()
      end
      
      function M.tform:onkeydown()
      end
      
      function M.tform:onkeyup()
      end
      
      M.tcloseaction = class.new()
      
      function M.tcloseaction:new()
      end
      
      M.cafree = 0
      M.bsnone = 0
      M.ponone = 0
      M.poscreencenter = 1
      M.vk_up = -1
      M.vk_down = -2
      M.vk_left = -3
      M.vk_right = -4
      M.vk_control = -5
      M.vk_menu = -6
      M.vk_shift = -7
      M.vk_insert = -8
      
      return M
      
      ''';
  if Name = 'graphics' then
    Result := '''
      local class = system.loadunit 'class'
      
      local M = {}
      
      M.tfont = class.new()
      
      function M.tfont:new()
      end
      
      M.tpicture = system.newpicture
      
      M.default_charset = 0
      M.clwhite = 0xffffffff
      M.clfuchsia = 0xffff00ff
      M.clwindowtext = 0xff000000
      
      return M
      
      ''';
  if Name = 'jpeg' then
    Result := '''
      local M = {}
      return M
      
      ''';
  if Name = 'math' then
    Result := '''
      local math = require 'math'
      
      local M = {}
      
      M.floor = math.floor
      M.abs = math.abs
      
      return M
      
      ''';
  if Name = 'messages' then
    Result := '''
      local M = {}
      return M
      
      ''';
  if Name = 'registry' then
    Result := '''
      local class = system.loadunit 'class'
      
      local M = {}
      
      M.treginifile = class.new()
      
      function M.treginifile:new()
      end
      
      function M.treginifile:create()
        return M.treginifile()
      end
      
      function M.treginifile:readinteger( arg1, key, value )
        return system.loadvalue( key:lower() ) or value
      end
      
      function M.treginifile:writeinteger( arg1, key, value)
        system.savevalue( key:lower(), value )
      end
      
      return M
      
      ''';
  if Name = 'stdctrls' then
    Result := '''
      local class = system.loadunit 'class'
      local graphics = system.loadunit 'graphics'
      
      local M = {}
      
      M.tlabel = class.new()
      
      function M.tlabel:new()
        self.font = graphics.tfont()
      end
      
      M.tscrollbar = class.new()
      
      function M.tscrollbar:new()
      end
      
      return M
      
      ''';
  if Name = 'sysutils' then
    Result := '''
      local M = {}
      
      M.now = system.now
      M.decodetime = system.splittime
      M.inttostr = system.inttostr
      
      function M.decodedate( time )
        local hour, min, sec, msec, day, month, year = system.splittime( time )
        return day, month, year
      end
      
      return M
      
      ''';
  if Name = 'windows' then
    Result := '''
      local M = {}
      return M
      
      ''';
end;

end.

