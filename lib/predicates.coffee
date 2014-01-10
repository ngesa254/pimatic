__ = require("i18n").__
Q = require 'q'
assert = require 'cassert'

class PredicateProvider
  # This function should return 'event' or 'state' if the sensor can decide the given predicate.
  # If the sensor can decide the predicate and it is a one shot event like 'its 10pm' then the
  # canDecide should return `'event'`
  # If the sensor can decide the predicate and it can be true or false like 'x is present' then 
  # canDecide should return `'state'`
  # If the sensor can not decide the given predicate then canDecide should return `false`
  canDecide: (predicate) ->
    throw new Error("your sensor must implement canDecide")

  # The sensor should return `true` if the predicate is true and `false` if it is false.
  # If the sensor can not decide the predicate or the predicate is an eventthis function 
  # should throw an Error.
  isTrue: (id, predicate) ->
    throw new Error("your sensor must implement itTrue")

  # The sensor should call the callback if the state of the predicate changes (it becomes true or 
  # false).
  # If the sensor can not decide the predicate this function should throw an Error.
  notifyWhen: (id, predicate, callback) ->
    throw new Error("your sensor must implement notifyWhen")

  # Cancels the notification for the predicate with the id given id.
  cancelNotify: (id) ->
    throw new Error("your sensor must implement cancelNotify")

env = null

class DeviceEventPredicateProvider extends PredicateProvider
  _listener: {}

  canDecide: (predicate) ->
    info = @_parsePredicate predicate
    return if info? then 'state' else no 

  isTrue: (id, predicate) ->
    info = @_parsePredicate predicate
    if info? then return info.getPredicateValue()
    else throw new Error "Can not decide \"#{predicate}\"!"

  # Removes the notification for an with `notifyWhen` registered predicate. 
  cancelNotify: (id) ->
    listener = @_listener[id]
    if listener?
      listener.destroy()
      delete @_listener[id]

  # Registers notification. 
  notifyWhen: (id, predicate, callback) ->
    info = @_parsePredicate predicate
    if info?
      device = info.device
      event = info.event
      eventListener = info.getEventListener(callback)

      device.on event, eventListener

      @_listener[id] =
        id: id
        present: info.present
        destroy: => device.removeListener event, eventListener

    else throw new Error "DeviceEventPredicateProvider can not decide \"#{predicate}\"!"

  _parsePredicate: (predicate) ->
    throw new Error 'Should be implemented by supper class.'


class PresentPredicateProvider extends DeviceEventPredicateProvider

  constructor: (_env, @framework) ->
    env = _env

  _parsePredicate: (predicate) ->
    predicate = predicate.toLowerCase()
    regExpString = '^(.+)\\s+is\\s+(not\\s+)?present$'
    matches = predicate.match (new RegExp regExpString)
    if matches?
      deviceName = matches[1].trim()
      negated = (if matches[2]? then yes else no) 
      for id, d of @framework.devices
        if d.getSensorValuesNames? and 'present' in d.getSensorValuesNames()
          if d.matchesIdOrName deviceName
            return info =
              device: d
              event: 'present'
              getPredicateValue: => 
                d.getSensorValue('present').then (present) =>
                  if negated then not present else present
              getEventListener: (callback) => 
                return eventListener = (present) => 
                  callback(if negated then not present else present)
              negated: negated # for testing only
    return null



class SensorValuePredicateProvider extends DeviceEventPredicateProvider

  constructor: (_env, @framework) ->
    env = _env

  _compareValues: (comparator, value, referenceValue) ->
    unless isNaN value
      value = parseFloat value
    return switch comparator
      when '==' then value is referenceValue
      when '!=' then value isnt referenceValue
      when '<' then value < referenceValue
      when '>' then value > referenceValue
      else throw new Error "Unknown comparator: #{comparator}"


  _parsePredicate: (predicate) ->
    predicate = predicate.toLowerCase()
    regExpString = 
      '^(.+)\\s+' + # the sensor value
      'of\\s+' + # of
      '(.+?)\\s+' + # the sensor
      '(?:is\\s+)?' + # is
      '(equal\\s+to|equals*|lower|less|greater|is not|is)' + 
        # is, is not, equal, equals, lower, less, greater
      '(?:|\\s+equal|\\s+than|\\s+as)?\\s+' + # equal to, equal, than, as
      '(.+)' # reference value
    matches = predicate.match (new RegExp regExpString)
    if matches?
      sensorValueName = matches[1].trim().toLowerCase()
      sensorName = matches[2].trim().toLowerCase()
      comparator = matches[3].trim() 
      referenceValue = matches[4].trim()

      if (referenceValue.match /.*for .*/)? then return null
      #console.log "#{sensorValueName}, #{sensorName}, #{comparator}, #{referenceValue}"
      for id, d of @framework.devices
        if d.getSensorValuesNames?
          if d.matchesIdOrName sensorName
            if sensorValueName in d.getSensorValuesNames()
              comparator = switch  
                when comparator in ['is', 'equal', 'equals', 'equal to', 'equals to'] then '=='
                when comparator is 'is not' then '!='
                when comparator is 'greater' then '>'
                when comparator in ['lower', 'less'] then '<'
                else 
                  env.logger.error "Illegal comparator \"#{comparator}\""
                  false

              unless comparator is false
                unless isNaN(referenceValue)
                  referenceValue = parseFloat referenceValue

                lastState = null
                return info =
                  device: d
                  event: sensorValueName
                  getPredicateValue: => 
                    d.getSensorValue(sensorValueName).then (value) =>
                      @_compareValues comparator, value, referenceValue
                  getEventListener: (callback) => 
                    return sensorValueListener = (value) =>
                      state = @_compareValues comparator, value, referenceValue
                      if state isnt lastState
                        lastState = state
                        callback state
                  comparator: comparator # for testing only
                  sensorValueName: sensorValueName # for testing only
                  referenceValue: referenceValue


    return null


module.exports.PredicateProvider = PredicateProvider
module.exports.PresentPredicateProvider = PresentPredicateProvider
module.exports.SensorValuePredicateProvider = SensorValuePredicateProvider