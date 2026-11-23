---
title: SAMPLE Utility shut-offs
kind: steps
when: SAMPLE you smell gas or [Fill in: what else]{a pipe bursts}.
guides: utility-shutoff
sources: SAMPLE utility's safety page
checked: 2026-11-16
walked: 2026-10-04
danger: SAMPLE if you smell gas, get everyone out first and call from outside.
need: sample pipe wrench; sample flashlight
next: SAMPLE call a plumber or the gas company.
things: #7 SAMPLE wrench; SAMPLE old towels
---
- step: SAMPLE do you smell gas near the meter?
  name: SAMPLE smell gas
  yes: 2
  no: 3
  checked: c276b32d
- step: SAMPLE get everyone out the front door.
  name: SAMPLE get out
  danger: SAMPLE don't use a light switch inside.
  map: yes
  meet: yes
  call: 5555550142; SAMPLE gas emergency line
  checked: e4f2e76f
- step: SAMPLE turn the handle a quarter turn [Fill in: left or right?], so it lies across the pipe.
  name: SAMPLE water main
  caution: SAMPLE don't force a stuck valve.
  wanted: SAMPLE the valve with its handle across the pipe
  guide: utility-shutoff
  items: sample pipe wrench
  checked: a6a7e98f
  place: #14 SAMPLE Garage › Utility shelf
  manual: #7 SAMPLE Generator
- step: SAMPLE at the panel, do each of these.
  name: SAMPLE breaker panel
  photo: sample-shutoffs-4.jpg
  calculator: calc-outage-load
  ticks: SAMPLE switch the main breaker down; SAMPLE write the time on the panel door
  checked: cb1a5d8a
  place: SAMPLE Back yard
