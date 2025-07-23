Engine_Cule : CroneEngine {

	classvar nVoices = 3;
	classvar nRecordedModulators = 8;
	classvar bufferRateScale = 0.5;
	classvar maxLoopTime = 60;

	var opTypeDefNames;
	var modulationDests;
	var modulationSources;
	var patchOptions;
	var patchArgs;
	var selectedVoiceArgs;

	var fmRatios;
	var fmRatiosInterleaved;
	var fmIntervals;
	var nRatios;

	// var d50Resources;
	var sq80Resources;

	var group;
	var baseFreqBus;
	var clockPhaseBus;
	var clockSynth;
	var voiceParamBuses;
	var voiceModBuses;
	var voiceOutputBuses;
	var voiceOpStates;
	var voiceSynths;
	var patchBuses;
	var replySynth;
	var polls;
	var opFadeReplyFunc;
	var opTypeReplyFunc;
	var fxTypeReplyFunc;
	var lfoTypeReplyFunc;
	var voiceAmpReplyFunc;
	var voicePitchReplyFunc;
	var lfoGateReplyFunc;

	var selectedVoice = 0;

	*new { arg context, doneCallback;
		^super.new(context, doneCallback);
	}

	// helper function / pseudo-UGen: an FM operator that can crossfade its tuning across a set
	// of predefined ratios
	harmonicOsc {
		arg uGen, hz, harmonic, uGenArg;
		var whichRatio = harmonic.linlin(-1, 1, 0, nRatios - 1);
		var whichOsc = (Fold.kr(whichRatio).linlin(0, 1, -1, 1) * 1.25).clip2;
		^LinXFade2.ar(
			uGen.ar(hz * Select.kr(whichRatio + 1 / 2, fmRatiosInterleaved[0]), uGenArg),
			uGen.ar(hz * Select.kr(whichRatio / 2, fmRatiosInterleaved[1]), uGenArg),
			whichOsc
		);
	}

	applyFx {
		arg dry, wet;
		// below -0.99 intensity, wet signal will be fully mixed out, so synth can be paused
		var blendAmount = \intensity.ar.linlin(-0.99, -0.9, -1, 1).lag(0.1);
		var blended = LinXFade2.ar(dry, wet, blendAmount);
		^ReplaceOut.ar(\bus.ir, blended);
	}

	buildRomplerDefs {
		arg prefix, baseFreq, path, waveParamsArray, waveMapsLoopArray, waveMapsOneShotArray;

		// start, end, and pitch offset from baseFreq
		var waveParamsWithPitchesCalculated = waveParamsArray.collect({
			arg params;
			var pitchAdjusted = [ params[0], params[1], (params[2] - (params[3] / 128)).midiratio ];
			pitchAdjusted;
		});
		var waveParams = Buffer.loadCollection(context.server, waveParamsWithPitchesCalculated.flatten, 3);
		var waveMapsLoop = Buffer.loadCollection(context.server, waveMapsLoopArray.flatten, 16);
		var waveMapsOneShot = Buffer.loadCollection(context.server, waveMapsOneShotArray.flatten, 16);
		var sampleData = Buffer.read(context.server, path, 0, -1);

		// Looping sample player
		SynthDef.new(prefix.asString ++ "Loop", {
			var whichRatio = \ratio.kr.linlin(-1, 1, 0, nRatios);
			var pitch = \pitch.kr + Select.kr(whichRatio, fmIntervals);
			var rate = 2.pow(pitch) * In.kr(baseFreqBus) / baseFreq;
			// TODO: the use of 'index' here means sample choice is modulated by amp by default,
			// which usually doesn't sound great, and is confusing. use \ratio instead??
			// and index could control... uhhhhhhhhhh... saturation... tone... something
			// -- something such as phase modulation... or sync or something
			var whichMap = \index.ar.linlin(-1, 1, 0, waveMapsLoopArray.size - 0.5).trunc;
			var whichRange = pitch.linlin(-1/24, 23/24, 9, 10.5, nil);
			var whichWave = Select.ar(whichRange, BufRd.ar(16, waveMapsLoop, whichMap, interpolation: 1));
			var duckTime = 0.005;
			var waveChanged = Trig.ar(Changed.ar(whichWave) + Impulse.ar(0), duckTime);
			var duckEnv = Env.new([1, 0, 0, 1], [duckTime, SampleDur.ir, duckTime]).ar(gate: waveChanged);
			var delayedTrig = TDelay.ar(waveChanged, duckTime);
			var params = Latch.ar(
				BufRd.ar(3, waveParams, whichWave, interpolation: 1),
				delayedTrig
			);
			var phase = Phasor.ar(delayedTrig, rate * params[2], params[0], params[1], params[0]);
			Out.ar(\outBus.ir, BufRd.ar(1, sampleData, phase, 0, 4) * duckEnv);
		}).add;

		// One-shot sample player
		SynthDef.new(prefix.asString ++ "OneShot", {
			var whichRatio = \ratio.kr.linlin(-1, 1, 0, nRatios);
			var pitch = \pitch.kr + Select.kr(whichRatio, fmIntervals);
			var rate = 2.pow(pitch) * In.kr(baseFreqBus) / baseFreq;
			var whichMap = \index.ar.linlin(-1, 1, 0, waveMapsOneShotArray.size - 0.5).trunc;
			var whichRange = pitch.linlin(0, 1, 9, 10.5, nil);
			var whichWave = Select.ar(whichRange, BufRd.ar(16, waveMapsOneShot, whichMap, interpolation: 1));
			// retrigger on sample change
			var duckTime = 0.003;
			var trig = Trig.ar(\trig.tr, duckTime); // don't retrigger DURING a duck
			var duckEnv = Env.new([1, 0, 0, 1], [duckTime, SampleDur.ir, duckTime]).ar(gate: trig);
			var delayedTrig = TDelay.ar(trig, duckTime);
			var params = Latch.ar(
				BufRd.ar(3, waveParams, whichWave, interpolation: 1),
				delayedTrig
			);
			var phase = (params[0] + Sweep.ar(delayedTrig, rate * SampleRate.ir * params[2]));
			Out.ar(\outBus.ir, BufRd.ar(1, sampleData, phase.min(params[1]), 0, 4) * duckEnv);
		}).add;

		// return buffers so we can free them later
		^[ waveParams, waveMapsLoop, waveMapsOneShot, sampleData ];
	}

	swapOp {
		arg v, op; // op A = 0, B = 1
		var opState = voiceOpStates[v][op];
		var defNames = opTypeDefNames[opState[\type]];
		// some op types have separate versions for fade and non-fade, others don't
		var defName = if(defNames.class === Array, {
			// fade-specific op type
			defNames[opState[\fade]]
		}, defNames);
		var paramBuses = voiceParamBuses[v];
		var outputBuses = voiceOutputBuses[v];
		var synths = voiceSynths[v];
		var thisBus = Bus.newFrom(outputBuses[\ops], op);
		var thatBus = Bus.newFrom(outputBuses[\ops], 1 - op);
		var newOp = Synth.replace(synths[\ops][op], defName, [
			\inBus, thatBus,
			\outBus, thisBus
		]);
		newOp.map(\pitch, Bus.newFrom(paramBuses[\opPitch], op));
		newOp.map(\ratio, Bus.newFrom(paramBuses[\opRatio], op));
		newOp.map(\index, Bus.newFrom(paramBuses[\opIndex], op));
		newOp.map(\trig, voiceOutputBuses[v][\trig]);
		synths[\ops].put(op, newOp);
	}

	swapFx {
		arg v, slot, defName;
		var paramBuses = voiceParamBuses[v];
		var synths = voiceSynths[v];
		var bus = voiceOutputBuses[v][\mixAudio];
		var newFx = Synth.replace(synths[\fx][slot], defName, [
			\bus, bus
		]);
		newFx.map(\intensity, Bus.newFrom(paramBuses[\fx], slot));
		synths[\control].set([ \fxASynth, \fxBSynth ].at(slot), newFx);
		synths[\fx].put(slot, newFx);
	}

	swapLfo {
		arg v, slot, defName;
		var paramBuses = voiceParamBuses[v];
		var synths = voiceSynths[v];
		var newLfo = Synth.replace(synths[\lfos][slot], defName, [
			\stateBus, Bus.newFrom(voiceOutputBuses[v][\lfos], slot),
			\voiceIndex, v,
			\lfoIndex, slot
		]);
		newLfo.map(\freq, Bus.newFrom(paramBuses[\lfoFreq], slot));
		synths[\lfos].put(slot, newLfo);
	}

	timbreLock {
		arg v, state;
		var synths = voiceSynths[v];
		if(state, {
			// explicitly set this voice's synths' args, which unmaps them from patch buses
			patchBuses.keysValuesDo({ |name, patchBus|
				if(name === \mod, {
					patchBus.keysValuesDo({ |sourceName, dests|
						// TODO NOW: double check this...
						// was dests[sourceName].keysValuesDo({ |destName, bus|
						dests.keysValuesDo({ |destName, modBus|
							modBus.get({ |value|
								synths[\mod][sourceName].set(destName, value);
							});
						});
					});
				}, {
					patchBus.get({ |value|
						synths[\control].set(name, value);
					});
				});
			});
		}, {
			// re-map all patch args to this voice's synths
			patchBuses.keysValuesDo({ |name, patchBus|
				if(name === \mod, {
					patchBus.keysValuesDo({ |sourceName, dests|
						dests.keysValuesDo({ |destName, modBus|
							synths[\mod][sourceName].map(destName, modBus);
						});
					});
				}, {
					synths[\control].map(name, patchBus);
				});
			});
		});
	}

	alloc {

		"alloc - syncing".postln;
		context.server.sync;
		"synced, starting alloc".postln;

		opTypeDefNames = [
			[ \operatorFM, \operatorFMFade ],
			[ \operatorFB, \operatorFBFade ],
			[ \operatorSQ80Loop, \operatorSQ80OneShot ],
			[ \operatorSquare, \operatorSquareFade ],
			[ \operatorSaw, \operatorSawFade ],
			\operatorKarp,
			\operatorComb,
			\operatorCombExt,
			[ \operatorFMD, \operatorFMDFade ],
			\nothing
		];

		// modulatable parameters for audio synths
		modulationDests = Dictionary[
			\amp -> \ar,
			\pan -> \kr,
			\loopPosition -> \kr,
			\loopRate -> \kr,
			\ratioA -> \kr,
			\detuneA -> \kr,
			\indexA -> \ar,
			\ratioB -> \kr,
			\detuneB -> \kr,
			\indexB -> \ar,
			\opMix -> \kr,
			\fxA -> \kr,
			\fxB -> \kr,
			\hpCutoff -> \ar,
			\lpCutoff -> \ar,
			\attack -> \kr,
			\release -> \kr,
			\lfoAFreq -> \kr,
			\lfoBFreq -> \kr,
			\lfoCFreq -> \kr,
		];

		// modulation sources
		modulationSources = Dictionary[
			\amp -> \ar,
			\hand -> \kr,
			\vel -> \kr,
			\svel -> \kr,
			\eg -> \ar,
			\eg2 -> \ar,
			\lfoA -> \kr,
			\lfoB -> \kr,
			\lfoC -> \kr,
			\sh -> \kr
		];

		// non-slewed settings
		patchOptions = [
			\opFadeA,
			\opTypeA,
			\opFadeB,
			\opTypeB,
			\fxTypeA,
			\fxTypeB,
			\egType,
			\ampMode,
			\lfoTypeA,
			\lfoTypeB,
			\lfoTypeC
		];

		// modulatable AND non-modulatable parameters
		patchArgs = [
			\pitchSlew,
			\hpRQ,
			\lpRQ,
			patchOptions,
			// TODO: is there a more elegant way to do this...? declare these as voice params, not set patch-wide?
			modulationDests.keys.difference([ \amp, \pan, \loopPosition, \loopRate ]).asArray,
		].flatten;

		// frequency ratios used by the two FM operators of each voice
		// declared as one array, but stored as two arrays, one with odd and one with even
		// members of the original; this allows operators to crossfade between two ratios
		// (see harmonicOsc function)
		fmRatios = [1/128, 1/64, 1/32, 1/16, 1/8, 1/4, 1/2,
			1, 2, /* 3, */ 4, /* 5, */ 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16];
		fmRatiosInterleaved = fmRatios.clump(2).flop;
		fmIntervals = fmRatios.ratiomidi / 12;
		nRatios = fmRatios.size;

		baseFreqBus = Bus.control(context.server);

		clockPhaseBus = Bus.control(context.server);
		SynthDef.new(\clockPhasor, {
			var rate = \rate.kr;
			var downbeat = \downbeat.tr;
			// at each downbeat, hard-reset the phasor to 0, 1, 2, 3, 0...
			var beat = Stepper.kr(downbeat, 0, 0, 3);
			var phase = Phasor.kr(downbeat, rate, 0, 4, resetPos: beat);
			// now shift the whole thing up to compensate for:
			// 1. message latency -- downbeat triggers will be sent using s.makeBundle for precise timing
			var latencyOffset = 0.1 * ControlRate.ir * rate;
			// 2. 1-block delay, because this phase will feed clocked LFOs that will also be fed by the
			// mod matrix, and then they'll only be fed BACK into the mod matrix 1 block later
			var blockOffset = rate;
			// 3. 0.01-second smoothing lag that gets applied to LFO outputs to avoid bad audible pops
			var lagOffset = 0.01 * ControlRate.ir * rate;
			Out.kr(clockPhaseBus, phase + latencyOffset + blockOffset + lagOffset);
		}).add;

		// modRouter_* synths write to these, and controlSynth synths read from them
		voiceModBuses = Array.fill(nVoices, {
			var buses = Dictionary.new;
			modulationDests.keysValuesDo({ |destName, rate|
				var bus = if(rate === \kr, {
					Bus.control(context.server);
				}, {
					Bus.audio(context.server);
				});
				buses.put(destName, bus);
			});
			buses;
		});

		// controlSynth synths write to these, and ops/fx/LFOs/etc read from them
		voiceParamBuses = Array.fill(nVoices, {
			Dictionary[
				\amp -> Bus.audio(context.server),
				\pan -> Bus.control(context.server),
				\pitch -> Bus.control(context.server),
				\opPitch -> Bus.control(context.server, 2),
				\opRatio -> Bus.control(context.server, 2),
				\opIndex -> Bus.audio(context.server, 2),
				\opMix -> Bus.control(context.server),
				\fx -> Bus.control(context.server, 2),
				\cutoff -> Bus.audio(context.server, 2),
				\rq -> Bus.control(context.server, 2),
				\lfoFreq -> Bus.control(context.server, 3),
				\outLevel -> Bus.control(context.server)
			];
		});

		voiceOutputBuses = Array.fill(nVoices, {
			var dict = Dictionary[
				\ops -> Bus.audio(context.server, 2),
				\mixAudio -> Bus.audio(context.server),
				\amp -> Bus.audio(context.server),
				\hand -> Bus.control(context.server),
				\trig -> Bus.control(context.server),
				\vels -> Bus.control(context.server, 2),
				\egs -> Bus.audio(context.server, 2),
				\lfos -> Bus.control(context.server, 3),
				\sh -> Bus.control(context.server)
			];
			// create aliases for the above, for easy reading in mod matrix
			dict.put(\opA, Bus.newFrom(dict[\ops], 0));
			dict.put(\opB, Bus.newFrom(dict[\ops], 1));
			dict.put(\vel, Bus.newFrom(dict[\vels], 0));
			dict.put(\svel, Bus.newFrom(dict[\vels], 1));
			dict.put(\eg, Bus.newFrom(dict[\egs], 0));
			dict.put(\eg2, Bus.newFrom(dict[\egs], 1));
			dict.put(\lfoA, Bus.newFrom(dict[\lfos], 0));
			dict.put(\lfoB, Bus.newFrom(dict[\lfos], 1));
			dict.put(\lfoC, Bus.newFrom(dict[\lfos], 2));
		});

		// patch buses dictionary: [
		//   param1 -> bus,
		//   param2 -> bus,
		//   ...
		//   mod -> [
		//     source -> [
		//       dest1 -> bus,
		//       dest2 -> bus,
		//       ...
		//     ]
		//   ]
		// ]
		patchBuses = Dictionary.new;
		patchArgs.do({ |name|
			patchBuses.put(name, Bus.control(context.server));
		});
		patchBuses.put(\mod, Dictionary.new);
		modulationSources.keysValuesDo({ |sourceName, sourceRate|
			patchBuses[\mod].put(sourceName, Dictionary.new);
			modulationDests.keysValuesDo({ |destName, destRate|
				patchBuses[\mod][sourceName].put(destName, Bus.control(context.server));
			});
		});

		SynthDef.new(\modRouter_kr, {
			var input = In.kr(\inBus.kr);
			modulationDests.keysValuesDo({ |name, rate|
				var outBus = NamedControl.kr(name ++ 'Mod');
				var amount = NamedControl.kr(name, 0.1);
				if(rate === \kr, {
					Out.kr(outBus, amount * input);
				}, {
					Out.ar(outBus, K2A.ar(amount * input));
				});
			});
		}).add;

		SynthDef.new(\modRouter_ar, {
			var input = InFeedback.ar(\inBus.kr);
			modulationDests.keysValuesDo({ |name, rate|
				var outBus = NamedControl.kr(name ++ 'Mod');
				var amount = NamedControl.kr(name, 0.1);
				if(rate === \kr, {
					Out.kr(outBus, A2K.kr(amount * input));
				}, {
					Out.ar(outBus, amount * input);
				});
			});
		}).add;

		SynthDef.new(\modRouter_amp, {
			var amp = InFeedback.ar(\inBus.kr);
			modulationDests.keysValuesDo({ |name, rate|
				var outBus = NamedControl.kr(name ++ 'Mod');
				var amount = NamedControl.kr(name, 0.1);
				if(rate === \kr, {
					Out.kr(outBus, A2K.kr(amount * amp));
				}, {
					if([ \indexA, \indexB, \hpCutoff, \lpCutoff ].includes(name), {
						var polaritySwitch = BinaryOpUGen(if(\hpCutoff === name, '<', '>'), amount, 0);
						Out.ar(outBus, (amp - polaritySwitch) * 2 * amount);
					}, {
						Out.ar(outBus, amount * amp);
					});
				});
			});
		}).add;

		SynthDef.new(\voiceControls, {

			var bufferRate, bufferLength, buffer,
				freeze, loopLength, loopPhase, bufferPhase,
				freezeWithoutGate,
				pitch, gate, trig, tip, hand, x, y,
				recPitch, recGate, recTrig, recTip, recHand, recX, recY,
				vel, svel, attack, release, eg, eg2,
				amp, fxA, fxB;

			// watch type op/fx/lfo type parameters and send signals to sclang to
			// handle op, fx, and lfo type changes
			// TODO: is this really the best place to do this?? why not just create engine commands??
			// oh right -- this way all voices can read from the patch bus, and not pick up changes if they're locked
			var voiceIndex = \voiceIndex.ir;
			Dictionary[
				\opFade -> [ \opFadeA, \opFadeB ],
				\opType -> [ \opTypeA, \opTypeB ],
				\fxType -> [ \fxTypeA, \fxTypeB ],
				\lfoType -> [ \lfoTypeA, \lfoTypeB, \lfoTypeC ]
			].keysValuesDo({ |typeName, controlNames|
				var path = '/' ++ typeName;
				controlNames.do({ |controlName, i|
					var value = NamedControl.kr(controlName);
					SendReply.kr(Changed.kr(value), path, [ voiceIndex, i, value ]);
				});
			});

			// create buffer for looping control data
			bufferRate = ControlRate.ir * bufferRateScale;
			bufferLength = context.server.sampleRate / context.server.options.blockSize * maxLoopTime * bufferRateScale;
			buffer = LocalBuf.new(bufferLength, nRecordedModulators);
			freeze = \freeze.kr;
			loopLength = (\loopLength.kr * bufferRate).min(bufferLength);
			loopPhase = Phasor.kr(
				Trig.kr(freeze) + \loopReset.tr,
				bufferRateScale * \loopRate.kr * 8.pow(\loopRateMod.kr),
				0, loopLength, 0
			);
			// offset by loopPosition, but constrain to loop bounds
			loopPhase = (loopPhase + (loopLength * (\loopPosition.kr + \loopPositionMod.kr))).wrap(0, loopLength);

			// define what we'll be writing
			pitch = \pitch.kr;
			tip = \tip.kr;
			hand = tip - \palm.kr;
			x = \dx.kr;
			y = \dy.kr;
			gate = \gate.kr;
			trig = Trig.kr(\trig.tr, 0.01);

			bufferPhase = Phasor.kr(rate: bufferRateScale * (1 - freeze), end: bufferLength);
			BufWr.kr([pitch, tip, hand, x, y, gate, trig], buffer, bufferPhase);
			// read values from recorded loop (if any)
			# recPitch, recTip, recHand, recX, recY, recGate, recTrig = BufRd.kr(
				nRecordedModulators,
				buffer,
				bufferPhase - loopLength + loopPhase,
				interpolation: 1
			);
			// new pitch values can "punch through" frozen ones when gate is high
			freezeWithoutGate = freeze.min(1 - gate);
			pitch = Select.kr(freezeWithoutGate, [ pitch, recPitch + \shift.kr ]);
			// punch tip through too, only when gate is high
			tip = Select.kr(freezeWithoutGate, [ tip, recTip ]);
			// mix incoming hand and x/y data with recorded data (fade in when freeze is engaged)
			# hand, x, y = [ hand, x, y ] + (Linen.kr(freeze, 0.3, 1, 0) * [ recHand, recX, recY ]);
			// combine incoming gates with recorded gates
			gate = gate.max(freeze * recGate);
			trig = trig.max(freeze * recTrig);

			Out.kr(\handBus.ir, hand.lag(0.1));
			Out.kr(\trigBus.ir, trig);

			attack = \attack.kr * 8.pow(\attackMod.kr);
			release = \release.kr * 8.pow(\releaseMod.kr);
			eg = Select.ar(\egType.kr(1), [
				// ASR, linear attack
				Env.new(
					[0, 1, 0],
					[attack, release],
					[0, -6],
					releaseNode: 1
				).ar(gate: gate),
				// AR, Maths-style symmetrical attack
				Env.new(
					[0, 1, 0],
					[attack, release],
					[6, -6]
				).ar(gate: trig)
			]);
			eg2 = Env.perc(0.001, (attack + release) * 2 + 0.1, 2, -8).ar(gate: trig);
			Out.ar(\egBus.ir, [ eg, eg2 ]);

			// smooth vel is smoothed *before* distance calculation
			// TODO: update x/y more frequently and you can reduce the lag here
			vel = Mix(Lag.kr([ x, y ], \xylag.kr(0.1)).squared).sqrt;
			// sampled vel is unsmoothed
			svel = Latch.kr(Mix([ x, y ].squared).sqrt, trig);
			// .lincurve scales just slightly to make vels more sensitive to small movements
			Out.kr(\velBus.ir, [ vel, svel ].lincurve(0, 2, 0, 2, -1, nil));

			Out.kr(\opRatioBus.ir, [
				\ratioA.kr(lag: 0.1, fixedLag: true) + \ratioAMod.kr,
				\ratioB.kr(lag: 0.1, fixedLag: true) + \ratioBMod.kr
			]);

			Out.ar(\opIndexBus.ir, [
				\indexA.ar(lag: 0.1) + \indexAMod.ar,
				\indexB.ar(lag: 0.1) + \indexBMod.ar
			]);

			Out.kr(\opMixBus.ir, \opMix.kr(lag: 0.1, fixedLag: true) + \opMixMod.kr);

			fxA = \fxA.kr(lag: 0.1, fixedLag: true) + \fxAMod.kr;
			fxB = \fxB.kr(lag: 0.1, fixedLag: true) + \fxBMod.kr;
			Out.kr(\fxBus.ir, [ fxA, fxB ]);
			// when FX amounts go to (almost) 0, wait 0.1s for fade (see applyFx), then pause them
			Pause.kr(
				Env.new(
					times: [ 0, 0.1 ],
					releaseNode: 1,
					curve: \hold
				).kr(gate: [ fxA, fxB ] > -0.99),
				[ \fxASynth.kr, \fxBSynth.kr ]
			);

			Out.ar(\cutoffBus.ir, [
				\hpCutoff.ar(lag: 0.1) + \hpCutoffMod.ar,
				\lpCutoff.ar(lag: 0.1) + \lpCutoffMod.ar
			]);

			Out.kr(\rqBus.ir, [
				\hpRQ.kr(lag: 0.1, fixedLag: true),
				\lpRQ.kr(lag: 0.1, fixedLag: true),
			]);

			Out.kr(\lfoFreqBus.ir, [
				\lfoAFreq.kr(1) * 8.pow(\lfoAFreqMod.kr),
				\lfoBFreq.kr(1) * 8.pow(\lfoBFreqMod.kr),
				\lfoCFreq.kr(1) * 8.pow(\lfoCFreqMod.kr)
			]);

			// slew tip for direct control of amplitude -- otherwise there will be audible steppiness
			tip = Lag.ar(K2A.ar(tip), 0.05);
			// amp mode shouldn't change while frozen
			amp = Select.ar(K2A.ar(Gate.kr(\ampMode.kr, 1 - freeze)), [
				tip,
				tip * eg,
				eg * -6.dbamp
			]);
			amp = amp * (1 + \ampMod.ar);
			amp = amp.clip(0, 1);
			Out.ar(\ampBus.ir, amp);

			Out.kr(\shBus.ir, Latch.kr(WhiteNoise.kr, trig + Trig.kr(amp > 0.01)));

			Out.kr(\panBus.ir, \pan.kr(lag: 0.1, fixedLag: true) + \panMod.kr);

			pitch = Lag.kr(pitch, \pitchSlew.kr);
			Out.kr(\pitchBus.ir, pitch);

			Out.kr(\opPitchBus.ir, [
				\detuneA.kr(lag: 0.1).cubed + \detuneAMod.kr,
				\detuneB.kr(lag: 0.1).cubed + \detuneBMod.kr
			] * 1.17 + pitch);
			// max detune of 1.17 octaves is slightly larger than a ratio of 9/4

			Out.kr(\outLevelBus.ir, \outLevel.kr(0.2, lag: 0.1, fixedLag: true));
		}).add;

		// Triangle LFO
		SynthDef.new(\lfoTri, {
			var lfo = LFTri.kr(\freq.kr(1), 4.rand);
			var gate = lfo > 0;
			Out.kr(\stateBus.ir, lfo);
			SendReply.kr(Changed.kr(gate), '/lfoGate', [\voiceIndex.ir, \lfoIndex.ir, gate]);
		}).add;

		// Tempo-synced random step LFO
		SynthDef.new(\lfoSH, {
			var inPhase = In.kr(clockPhaseBus);
			var freq = \freq.kr(1);
			var rawMult = 2.pow(freq.log2.round); // frequency quantized to nearest power of 2
			// TODO: quantize to more fun divisions than this, like tuplets, dotted notes, etc
			var rawPhase = (inPhase * rawMult).wrap(0, 1);
			var rawGate = BinaryOpUGen('<', rawPhase, 0.5);
			// the 'raw' clock above is fine until you start modulating the frequency. then you get very
			// awkward jumps as mult changes.
			// in order to only change mult at note onsets, we derive ANOTHER clock whose frequency
			// is Latched by the raw clock.
			var mult = Latch.kr(rawMult, rawGate);
			var phase = (inPhase * mult).wrap(0, 1);
			var gate = BinaryOpUGen('<', phase, 0.5);
			// since S+H output will be lagged by 0.01, the clock we're being fed is 0.01s early.
			// that's good for triggering the S+H, but bad for clocking seq
			var delayedGate = DelayN.kr(gate, 0.01, 0.01);
			Out.kr(\stateBus.ir, Lag.kr(TRand.kr(-1, 1, gate), 0.01));
			SendReply.kr(Changed.kr(delayedGate), '/lfoGate', [\voiceIndex.ir, \lfoIndex.ir, delayedGate]);
		}).add;

		// Random Dust step LFO
		SynthDef.new(\lfoDust, {
			var freq = \freq.kr(1);
			var trig = Dust.kr(freq);
			var gate = Trig.kr(trig, (freq * 8).reciprocal);
			Out.kr(\stateBus.ir, Lag.kr(TRand.kr(-1, 1, trig), 0.01));
			SendReply.kr(Changed.kr(gate), '/lfoGate', [\voiceIndex.ir, \lfoIndex.ir, gate]);
		}).add;

		// Smooth random LFO
		SynthDef.new(\lfoDrift, {
			var freq = \freq.kr(1);
			var lfo = LFDNoise1.kr(LFNoise0.kr(freq * 0.5).linlin(0, 1, freq * 0.5, freq * 2));
			var gate = lfo > 0;
			Out.kr(\stateBus.ir, lfo);
			SendReply.kr(Changed.kr(gate), '/lfoGate', [\voiceIndex.ir, \lfoIndex.ir, gate]);
		}).add;

		// Ramp LFO
		SynthDef.new(\lfoRamp, {
			var lfo = LFSaw.kr(\freq.kr(1), 4.rand);
			var gate = lfo < 0;
			Out.kr(\stateBus.ir, Lag.kr(lfo, 0.01));
			SendReply.kr(Changed.kr(gate), '/lfoGate', [\voiceIndex.ir, \lfoIndex.ir, gate]);
		}).add;

		// Self-FM operator
		SynthDef.new(\operatorFB, {
			var hz = 2.pow(\pitch.kr) * In.kr(baseFreqBus);
			var whichRatio = \ratio.kr.linlin(-1, 1, 0, nRatios);
			var output = SinOscFB.ar(
				hz * Select.kr(whichRatio, fmRatios),
				\index.ar(-1).lincurve(-1, 1, 0, 1.3pi, 3, \min)
			);
			Out.ar(\outBus.ir, output);
		}).add;

		// Self-FM operator with crossfading between ratios
		SynthDef.new(\operatorFBFade, {
			var hz = 2.pow(\pitch.kr) * In.kr(baseFreqBus);
			var output = this.harmonicOsc(
				SinOscFB,
				hz,
				\ratio.kr,
				\index.ar(-1).lincurve(-1, 1, 0, 1.3pi, 3, \min)
			);
			Out.ar(\outBus.ir, output);
		}).add;

		// External-FM operator
		SynthDef.new(\operatorFM, {
			var pitch = \pitch.kr;
			var hz = 2.pow(pitch) * In.kr(baseFreqBus);
			var whichRatio = \ratio.kr.linlin(-1, 1, 0, nRatios);
			var output = SinOsc.ar(
				hz * Select.kr(whichRatio, fmRatios),
				(InFeedback.ar(\inBus.ir) * \index.ar(-1).lincurve(-1, 1, 0, 13pi, 4, \min) * 0.7.pow(pitch)).mod(2pi)
			);
			Out.ar(\outBus.ir, output);
		}).add;

		// External-FM operator with crossfading between ratios
		SynthDef.new(\operatorFMFade, {
			var pitch = \pitch.kr;
			var hz = 2.pow(pitch) * In.kr(baseFreqBus);
			var output = this.harmonicOsc(
				SinOsc,
				hz,
				\ratio.kr,
				(InFeedback.ar(\inBus.ir) * \index.ar(-1).lincurve(-1, 1, 0, 13pi, 4, \min) * 0.7.pow(pitch)).mod(2pi)
			);
			Out.ar(\outBus.ir, output);
		}).add;

		// External-FM operator with a tuned delay at its FM input
		SynthDef.new(\operatorFMD, {
			var pitch = \pitch.kr;
			var whichRatio = \ratio.kr.linlin(-1, 1, 0, nRatios);
			var hz = 2.pow(pitch) * In.kr(baseFreqBus);
			// we'll delay the input signal by the shortest possible amount of time
			// that is (a) greater than block size, and (b) an octave multiple of
			// the oscillator pitch
			var delaySafeHz = (hz / ControlRate.ir).ratiomidi.wrap(-12, 0).midiratio * ControlRate.ir;
			var delayTime = K2A.ar(delaySafeHz.reciprocal);
			var delayDelayBuf = LocalBuf.new(SampleRate.ir * 2);
			var delayedDelayTime = BufDelayN.ar(delayDelayBuf, delayTime, delayTime); // haha lol
			var delta = delayedDelayTime - delayTime;
			var deltaOrInf = Select.ar(delta, [DC.ar(inf), delta]);
			var slewedDelayTime = Slew.ar(
				delayTime,
				1 - 0.5.pow(deltaOrInf),
				2.pow(deltaOrInf) - 1
			);
			var delayBuf = LocalBuf.new(SampleRate.ir * 2);
			var delayedIn = BufDelayC.ar(
				delayBuf,
				InFeedback.ar(\inBus.ir),
				slewedDelayTime - (BlockSize.ir * SampleDur.ir)
			);
			var output = SinOsc.ar(
				hz * Select.kr(whichRatio, fmRatios),
				(delayedIn * \index.ar(-1).lincurve(-1, 1, 0, 13pi, 4, \min) * 0.7.pow(pitch)).mod(2pi)
			);
			Out.ar(\outBus.ir, output);
		}).add;

		// External-FM operator with a tuned delay at its FM input, crossfading between ratios
		// TODO: dry this out, ffs
		SynthDef.new(\operatorFMDFade, {
			var pitch = \pitch.kr;
			var hz = 2.pow(pitch) * In.kr(baseFreqBus);
			var delaySafeHz = (hz / ControlRate.ir).ratiomidi.wrap(-12, 0).midiratio * ControlRate.ir;
			var delayTime = K2A.ar(delaySafeHz.reciprocal);
			var delayDelayBuf = LocalBuf.new(SampleRate.ir * 2);
			var delayedDelayTime = BufDelayN.ar(delayDelayBuf, delayTime, delayTime); // haha lol
			var delta = delayedDelayTime - delayTime;
			var deltaOrInf = Select.ar(delta, [DC.ar(inf), delta]);
			var slewedDelayTime = Slew.ar(
				delayTime,
				1 - 0.5.pow(deltaOrInf),
				2.pow(deltaOrInf) - 1
			);
			var delayBuf = LocalBuf.new(SampleRate.ir * 2);
			var delayedIn = BufDelayC.ar(
				delayBuf,
				InFeedback.ar(\inBus.ir),
				slewedDelayTime - (BlockSize.ir * SampleDur.ir)
			);
			var output = this.harmonicOsc(
				SinOsc,
				hz,
				\ratio.kr,
				(delayedIn * \index.ar(-1).lincurve(-1, 1, 0, 13pi, 4, \min) * 0.7.pow(pitch)).mod(2pi)
			);
			Out.ar(\outBus.ir, output);
		}).add;

		// Karplus-Strong oscillator
		SynthDef.new(\operatorKarp, {
			var whichRatio = \ratio.kr.linlin(-1, 1, 0, nRatios);
			var hz = 2.pow(\pitch.kr) * In.kr(baseFreqBus) * Select.kr(whichRatio, fmRatios);
			var delayTime = K2A.ar(hz.reciprocal);
			var delayDelayBuf = LocalBuf.new(SampleRate.ir * 2);
			var delayedDelayTime = BufDelayN.ar(delayDelayBuf, delayTime, delayTime); // haha lol
			var delta = delayedDelayTime - delayTime;
			var deltaOrInf = Select.ar(delta, [DC.ar(inf), delta]);
			var slewedDelayTime = Slew.ar(
				delayTime,
				1 - 0.5.pow(deltaOrInf),
				2.pow(deltaOrInf) - 1
			);
			// excitation signal is a mix of noise and a "sine wave chirp", h/t Nathan Ho
			var trigEnv = Env.perc(0.001, 0.01).ar(gate: \trig.kr);
			var chirp = SinOsc.ar(trigEnv.linexp(0, 1, 20, 16000));
			var noise = WhiteNoise.ar(trigEnv);
			var decay = \index.ar(-1).linexp(-1, 1, -0.1, -32);
			var damping = hz.explin(20, 2000, 0.6, 0);
			var output = chirp * trigEnv + noise + Pluck.ar(chirp + noise, \trig.kr, 2, slewedDelayTime, decay, damping);
			Out.ar(\outBus.ir, output);
		}).add;

		// Comb filter
		SynthDef.new(\operatorComb, {
			var whichRatio = \ratio.kr.linlin(-1, 1, 0, nRatios);
			var hz = 2.pow(\pitch.kr) * In.kr(baseFreqBus) * Select.kr(whichRatio, fmRatios);
			// when desired pitch is higher than control rate, find the highest octave
			// DOWN from that pitch that will result in a delay time greater than the
			// block size.
			var delaySafeHz = hz.min((hz / ControlRate.ir).ratiomidi.wrap(-12, 0).midiratio * ControlRate.ir);
			var delayTime = K2A.ar(delaySafeHz.reciprocal);
			var delayDelayBuf = LocalBuf.new(SampleRate.ir * 2);
			var delayedDelayTime = BufDelayN.ar(delayDelayBuf, delayTime, delayTime); // haha lol
			var delta = delayedDelayTime - delayTime;
			var deltaOrInf = Select.ar(delta, [DC.ar(inf), delta]);
			var slewedDelayTime = Slew.ar(
				delayTime,
				1 - 0.5.pow(deltaOrInf),
				2.pow(deltaOrInf) - 1
			);
			var decayFactor = -60.dbamp.pow(slewedDelayTime / \index.ar(-1).lincurve(-1, 1, 0, 8, 8)).neg;
			var delayBuf = LocalBuf.new(SampleRate.ir * 2);
			var delayedIn = BufDelayC.ar(
				delayBuf,
				(LocalIn.ar * decayFactor).tanh + InFeedback.ar(\inBus.ir),
				slewedDelayTime - (BlockSize.ir * SampleDur.ir)
			);
			LocalOut.ar(delayedIn);
			Out.ar(\outBus.ir, delayedIn);
		}).add;

		// Comb with external audio input
		SynthDef.new(\operatorCombExt, {
			var whichRatio = \ratio.kr.linlin(-1, 1, 0, nRatios);
			var hz = 2.pow(\pitch.kr) * In.kr(baseFreqBus) * Select.kr(whichRatio, fmRatios);
			// when desired pitch is higher than control rate, find the highest octave
			// DOWN from that pitch that will result in a delay time greater than the
			// block size.
			var delaySafeHz = hz.min((hz / ControlRate.ir).ratiomidi.wrap(-12, 0).midiratio * ControlRate.ir);
			var delayTime = K2A.ar(delaySafeHz.reciprocal);
			var delayDelayBuf = LocalBuf.new(SampleRate.ir * 2);
			var delayedDelayTime = BufDelayN.ar(delayDelayBuf, delayTime, delayTime); // haha lol
			var delta = delayedDelayTime - delayTime;
			var deltaOrInf = Select.ar(delta, [DC.ar(inf), delta]);
			var slewedDelayTime = Slew.ar(
				delayTime,
				1 - 0.5.pow(deltaOrInf),
				2.pow(deltaOrInf) - 1
			);
			var decayFactor = -60.dbamp.pow(slewedDelayTime / \index.ar(-1).lincurve(-1, 1, 0, 8, 8)).neg;
			var delayBuf = LocalBuf.new(SampleRate.ir * 2);
			var delayedIn = BufDelayC.ar(
				delayBuf,
				(LocalIn.ar * decayFactor).tanh + SoundIn.ar,
				slewedDelayTime - (BlockSize.ir * SampleDur.ir)
			);
			LocalOut.ar(delayedIn);
			Out.ar(\outBus.ir, delayedIn);
		}).add;

		// Band-limited pseudo-analog oscillator, square-saw mix
		SynthDef.new(\operatorSquare, {
			var whichRatio = \ratio.kr.linlin(-1, 1, 0, nRatios);
			var hz = 2.pow(\pitch.kr) * In.kr(baseFreqBus) * Select.kr(whichRatio, fmRatios);
			var output = LinSelectX.ar(\index.ar(-1).linlin(-1, 1, 0, 1), [
				BlitB3Square.ar(hz),
				BlitB3Saw.ar(hz * 2)
			]);
			Out.ar(\outBus.ir, output * 6.dbamp);
		}).add;

		// Band-limited pseudo-analog oscillator, all square with fades between ratios and variable leak
		SynthDef.new(\operatorSquareFade, {
			var hz = 2.pow(\pitch.kr) * In.kr(baseFreqBus);
			var output = this.harmonicOsc(
				BlitB3Square,
				hz,
				\ratio.kr,
				\index.ar(-1).lincurve(-1, 1, 0.99, 0, 3)
			);
			Out.ar(\outBus.ir, output * 6.dbamp);
		}).add;

		// Band-limited pseudo-analog oscillator, square-saw mix
		SynthDef.new(\operatorSaw, {
			var whichRatio = \ratio.kr.linlin(-1, 1, 0, nRatios);
			var hz = 2.pow(\pitch.kr) * In.kr(baseFreqBus) * Select.kr(whichRatio, fmRatios);
			var output = LinSelectX.ar(\index.ar(-1).linlin(-1, 1, 0, 1), [
				BlitB3Saw.ar(hz),
				BlitB3Square.ar(hz / 2)
			]);
			Out.ar(\outBus.ir, output * 6.dbamp);
		}).add;

		// Band-limited pseudo-analog oscillator, all saw with fades between ratios and variable leak
		SynthDef.new(\operatorSawFade, {
			var hz = 2.pow(\pitch.kr) * In.kr(baseFreqBus);
			var output = this.harmonicOsc(
				BlitB3Saw,
				hz * 2,
				\ratio.kr,
				\index.ar(-1).lincurve(-1, 1, 0.99, 0, 3)
			);
			Out.ar(\outBus.ir, output * 6.dbamp);
		}).add;

		sq80Resources = this.buildRomplerDefs(
			\operatorSQ80,
			// these samples are (around?) 1024 samples per cycle.
			48000 / 1024,
			"/home/we/dust/data/fretware/sq80v2.wav",
			CSVFileReader.read("/home/we/dust/code/fretware/data/sq80-params.csv").asFloat,
			CSVFileReader.read("/home/we/dust/code/fretware/data/sq80-maps-loop.csv").asFloat,
			CSVFileReader.read("/home/we/dust/code/fretware/data/sq80-maps-oneshot.csv").asFloat
		);

		// d50Resources = this.buildRomplerDefs(
		// 	\operatorD50,
		// 	// looped slices are 2048 samples long, with 32 cycles per slice
		// 	// meaning 64 samples = 1 cycle
		// 	48000 / 64 / 2,
		// 	"/home/we/dust/data/fretware/d50.wav",
		// 	[
		// 		188417, 190465, 192513, 194561, 196609, 198657, 200705, 202753,
		// 		204801, 206849, 208897, 210945, 212993, 215041, 217089, 219137,
		// 		221185, 223233, 225281, 227329, 229377, 231425, 233473, 235521,
		// 		237569, 239617, 241665, 243713, 245761, 247809, 249857, 251905,
		// 		253953, 256001, 258049, 260097, nil, // one-shots start here
		// 		731137, 735233, 737281, 909313, 1040503, 1138690, 1202176, 1335304,
		// 		// next one is (kind of??) a one-shot again
		// 		nil, 1531905, 1712129, 1843201,
		// 		// the following start/end points are a little uncertain
		// 		1921025, nil, 2243046, 2408487, nil, 2539521, 2801627, 2985985,
		// 		3063807 // the end
		// 	].dupEach.shift(1).clump(2).reject({
		// 		arg range, index;
		// 		(index == 0) || range.includes(nil);
		// 	}).collect({ |pair| pair - [0, 1] }),
		// 	[
		// 		0, 4097, 8193, 12289, 16385, 24577, 26625, 28673,
		// 		30721, 32769, 34817, 36865, 40961, 45052, /* or maybe 45057 */ 47104, 49153,
		// 		57345, 65537, 73729, 81921, 86017, 90113, 94209, 98305,
		// 		102401, 106497, 110593, 114689, 118785, 122881, 126977, 131073,
		// 		135169, 139265, 143361, 147457, 149505, 151553, 155649, 157697,
		// 		159745, 163841, 167938, 172033, 176129, 180241, 184324, nil, // loops here
		// 		262145, 303107, 368641, 442371, 458754, 491522, 507906, 557058,
		// 		655362, 681988
		// 	].dupEach.shift(1).clump(2).reject({
		// 		arg range, index;
		// 		(index == 0) || range.includes(nil);
		// 	}).collect({ |pair| pair - [0, 1] })
		// );

		SynthDef.new(\operatorMixer, {
			// TODO: pause op synths when they're fully mixed out??
			var opA, opB, output;
			# opA, opB = In.ar(\opsBus.ir, 2);
			output = SelectX.ar(\mix.ar.linlin(-1, 1, 0, 4, nil).wrap(0, 3), [
				opA,
				opB,
				opA * opB * 3.dbamp, // compensate for amplitude loss from sine * sine
				opA
			]);
			Out.ar(\bus.ir, output);
		}).add;

		SynthDef.new(\nothing, {}).add;

		SynthDef.new(\fxSquiz, {
			var dry = In.ar(\bus.ir);
			var wet = Squiz.ar(
				dry,
				\intensity.ar.lincurve(-1, 1, 1, 16, 4, 'min'),
				2
			);
			this.applyFx(dry, wet);
		}).add;

		SynthDef.new(\fxWaveLoss, {
			var dry = In.ar(\bus.ir);
			var wet = WaveLoss.ar(
				dry,
				\intensity.ar.lincurve(-1, 1, 0, 127, 4, 'min'),
				127,
				mode: 2
			);
			this.applyFx(dry, wet);
		}).add;

		SynthDef.new(\fxFold, {
			var dry = In.ar(\bus.ir);
			var wet = (dry * \intensity.ar.linexp(-1, 1, 1, 27, 'min')).fold2;
			this.applyFx(dry, wet);
		}).add;

		SynthDef.new(\fxTanh, {
			var dry = In.ar(\bus.ir);
			var wet = (dry * \intensity.ar.linexp(-1, 1, 1, 49, 'min')).tanh;
			this.applyFx(dry, wet);
		}).add;

		SynthDef.new(\fxDecimator, {
			var dry = In.ar(\bus.ir);
			var intensity = \intensity.ar;
			var wet = Decimator.ar(
				dry,
				intensity.linexp(-1, 1, SampleRate.ir, 1500),
				intensity.linexp(-1, 1, 14, 1)
			);
			this.applyFx(dry, wet);
		}).add;

		// Dimension C-style chorus
		SynthDef.new(\fxChorus, {
			var dry = In.ar(\bus.ir);
			var intensity = \intensity.ar;
			var lfo = LFTri.kr(intensity.linexp(-1, 1, 0.015, 2, nil)).lag(0.1) * [-1, 1];
			var wet = Mix([
				dry,
				DelayL.ar(dry, 0.05, lfo * intensity.linexp(-1, 1, 0.0019, 0.005, nil) + [\d1.kr(0.01), \d2.kr(0.007)])
			].flatten);
			this.applyFx(dry, wet * -6.dbamp);
		}).add;

		// TODO: separate, swappable filter synths

		SynthDef.new(\voiceOutputStage, {

			var hpCutoff, hpRQ,
				lpCutoff, lpRQ;
			var voiceOutput = In.ar(\bus.ir);

			// HPF
			hpCutoff = \hpCutoff.ar(-1).linexp(-1, 1, 4, 24000);
			hpRQ = \hpRQ.kr(0.7).max(0.1);
			hpRQ = hpCutoff.linexp(SampleRate.ir * 0.25 / hpRQ, SampleRate.ir * 0.5, hpRQ, 0.5);
			voiceOutput = RHPF.ar(voiceOutput, hpCutoff, hpRQ);

			// LPF
			lpCutoff = IEnvGen.ar(
				Env.xyc([ [-1, 4], [\lpBreakpointIn.kr(-0.5), \lpBreakpointOut.kr(400), \exp], [1, 24000] ]),
				\lpCutoff.ar(1)
			);
			lpRQ = \lpRQ.kr(0.7).max(0.1);
			lpRQ = lpCutoff.linexp(SampleRate.ir * 0.25 / lpRQ, SampleRate.ir * 0.5, lpRQ, 0.5);
			voiceOutput = RLPF.ar(voiceOutput, lpCutoff, lpRQ);

			// scale by amplitude control value
			voiceOutput = voiceOutput * \amp.ar;

			// scale by output level
			voiceOutput = voiceOutput * Lag.kr(\outLevel.kr, 0.05);

			// pan and write to main outs
			Out.ar(context.out_b, Pan2.ar(voiceOutput, \pan.ar.fold2));
		}).add;

		// TODO NEXT: add engine commands to enable/disable these replies,
		// so we're not sending more messages than we need
		SynthDef.new(\reply, {
			arg replyRate = 15;
			var replyTrig = Impulse.kr(replyRate);
			nVoices.do({ |v|
				var amp = In.ar(voiceParamBuses[v][\amp]);
				var pitch = In.kr(voiceParamBuses[v][\pitch]);
				var trig = In.kr(voiceOutputBuses[v][\trig]);
				var pitchTrig = replyTrig + trig;

				// what's important is peak amplitude, not exact current amplitude at poll time
				amp = Peak.kr(amp, replyTrig);
				SendReply.kr(Peak.kr(Changed.kr(amp), replyTrig) * replyTrig, '/voiceAmp', [v, amp]);

				// respond quickly to triggers, which may change pitch in a meaningful way, even if the change is small
				SendReply.kr(Peak.kr(Changed.kr(pitch), pitchTrig) * pitchTrig, '/voicePitch', [v, pitch, trig]);
			});
		}).add;

		group = Group.new(context.og, \addBefore);

		context.server.sync;
		"defs sent".postln;

		baseFreqBus.setSynchronous(60.midicps);

		voiceOpStates = Array.fill(nVoices, {
			Array.fill(2, {
				Dictionary[
					\type -> 0,
					\fade -> 0,
				];
			});
		});

		clockSynth = Synth.new(\clockPhasor, [], group, \addToTail);

		voiceSynths = Array.fill(nVoices, { |i|

			var controlSynth, routerSynths, lfos, ops, mixBus, mixer, fx, out;

			var paramBuses = voiceParamBuses[i];
			var modBuses = voiceModBuses[i];
			var outputBuses = voiceOutputBuses[i];

			controlSynth = Synth.new(\voiceControls, [
				\voiceIndex, i,
				\ampBus, outputBuses[\amp],
				\handBus, outputBuses[\hand],
				\trigBus, outputBuses[\trig],
				\velBus, outputBuses[\vels],
				\egBus, outputBuses[\egs],
				\shBus, outputBuses[\sh]
			], group, \addToTail); // "output" group
			// write to this voice's parameter buses
			paramBuses.keysValuesDo({ |name, bus| controlSynth.set(name ++ 'Bus', bus) });
			// read params from patch buses
			patchArgs.do({ |name| controlSynth.map(name, patchBuses[name]) });
			// read modulation from this voice's mod buses
			modulationDests.keysValuesDo({ |name, rate|
				controlSynth.map(name ++ 'Mod', modBuses[name]);
			});

			// create mod router synths, map their inputs to controlSynth outputs and patch mod routings,
			// and write to voiceModBuses
			routerSynths = Dictionary.new;
			modulationSources.keysValuesDo({ |sourceName, sourceRate|
				var synth = Synth.new('modRouter_' ++ if(sourceName === \amp, \amp, sourceRate), [
					\inBus, outputBuses[sourceName]
				], group, \addToTail);
				modulationDests.keysValuesDo({ |destName, destRate|
					synth.map(destName, patchBuses[\mod][sourceName][destName]);
					synth.set(destName ++ 'Mod', modBuses[destName]);
				});
				routerSynths.put(sourceName, synth);
			});

			lfos = Array.fill(3, { |slot|
				var synth = Synth.new(\lfoTri, [
					\stateBus, Bus.newFrom(outputBuses[\lfos], slot),
					\voiceIndex, i,
					\lfoIndex, slot
				], group, \addToTail);
				synth.map(\freq, Bus.newFrom(paramBuses[\lfoFreq], slot));
			});

			ops = [ \operatorFB, \operatorFM ].collect({ |opType, otherOp|
				var op = 1 - otherOp;
				var thisBus = Bus.newFrom(outputBuses[\ops], op);
				var thatBus = Bus.newFrom(outputBuses[\ops], 1 - op);
				var synth = Synth.new(opType, [
					\inBus, thatBus,
					\outBus, thisBus
				], group, \addToTail);
				synth.map(\pitch, Bus.newFrom(paramBuses[\opPitch], op));
				synth.map(\ratio, Bus.newFrom(paramBuses[\opRatio], op));
				synth.map(\index, Bus.newFrom(paramBuses[\opIndex], op));
				synth.map(\trig, outputBuses[\trig]);
			}).reverse;

			mixBus = outputBuses[\mixAudio];
			mixer = Synth.new(\operatorMixer, [
				\opsBus, outputBuses[\ops],
				\bus, mixBus
			], group, \addToTail);
			mixer.map(\mix, paramBuses[\opMix]);

			fx = [ \fxSquiz, \fxWaveLoss ].collect({ |fxType, slot|
				var synth = Synth.new(fxType, [
					\bus, mixBus
				], group, \addToTail);
				synth.map(\intensity, Bus.newFrom(paramBuses[\fx], slot));
				controlSynth.set([ \fxASynth, \fxBSynth ].at(slot), synth);
				synth;
			});

			out = Synth.new(\voiceOutputStage, [
				\bus, mixBus
			], group, \addToTail);
			out.map(\amp,      paramBuses[\amp]);
			out.map(\pan,      paramBuses[\pan]);
			out.map(\hpCutoff, Bus.newFrom(paramBuses[\cutoff], 0));
			out.map(\hpRQ,     Bus.newFrom(paramBuses[\rq], 0));
			out.map(\lpCutoff, Bus.newFrom(paramBuses[\cutoff], 1));
			out.map(\lpRQ,     Bus.newFrom(paramBuses[\rq], 1));
			out.map(\outLevel, paramBuses[\outLevel]);

			context.server.sync;
			"voice % initialized\n".postf(i);

			Dictionary[
				\control -> controlSynth,
				\mod -> routerSynths,
				\ops -> ops,
				\mixer -> mixer,
				\fx -> fx,
				\lfos -> lfos,
				\out -> out
			];
		});

		replySynth = Synth.new(\reply, [], group, \addToTail);

		context.server.sync;
		"synths created".postln;

		polls = Array.fill(nVoices, { |i|
			i = i + 1;
			Dictionary[
				// TODO: poll env, vel, SH values too
				\instantPitch -> this.addPoll(("instant_pitch_" ++ i).asSymbol, periodic: false),
				\pitch -> this.addPoll(("pitch_" ++ i).asSymbol, periodic: false),
				\amp -> this.addPoll(("amp_" ++ i).asSymbol, periodic: false),
				\lfos -> [
					this.addPoll(("lfoA_gate_" ++ i).asSymbol, periodic: false),
					this.addPoll(("lfoB_gate_" ++ i).asSymbol, periodic: false),
					this.addPoll(("lfoC_gate_" ++ i).asSymbol, periodic: false)
				]
			];
		});

		opFadeReplyFunc = OSCFunc({ |msg|
			voiceOpStates[msg[3]][msg[4]][\fade] = msg[5];
			this.swapOp(msg[3], msg[4]);
		}, path: '/opFade', srcID: context.server.addr);

		opTypeReplyFunc = OSCFunc({ |msg|
			voiceOpStates[msg[3]][msg[4]][\type] = msg[5];
			this.swapOp(msg[3], msg[4]);
		}, path: '/opType', srcID: context.server.addr);

		fxTypeReplyFunc = OSCFunc({ |msg|
			var def = [\fxSquiz, \fxTanh, \fxFold, \fxWaveLoss, \fxDecimator, \fxChorus, \nothing].at(msg[5]);
			this.swapFx(msg[3], msg[4], def);
		}, path: '/fxType', srcID: context.server.addr);

		lfoTypeReplyFunc = OSCFunc({ |msg|
			var def = [\lfoTri, \lfoSH, \lfoDust, \lfoDrift, \lfoRamp, \nothing].at(msg[5]);
			this.swapLfo(msg[3], msg[4], def);
		}, path: '/lfoType', srcID: context.server.addr);

		voiceAmpReplyFunc = OSCFunc({ |msg|
			// msg looks like [ '/voiceAmp', ??, -1, voiceIndex, amp ]
			polls[msg[3]][\amp].update(msg[4]);
		}, path: '/voiceAmp', srcID: context.server.addr);

		voicePitchReplyFunc = OSCFunc({ |msg|
			// msg looks like [ '/voicePitch', ??, -1, voiceIndex, pitch, triggeredChange ]
			if(msg[5] == 1, {
				polls[msg[3]][\instantPitch].update(msg[4]);
			}, {
				polls[msg[3]][\pitch].update(msg[4]);
			});
		}, path: '/voicePitch', srcID: context.server.addr);

		lfoGateReplyFunc = OSCFunc({ |msg|
			// msg looks like [ '/lfoGate', ??, -1, voiceIndex, lfoIndex, state ]
			polls[msg[3]][\lfos][msg[4]].update(msg[5]);
		}, path: '/lfoGate', srcID: context.server.addr);

		context.server.sync;
		"polls and oscfuncs created".postln;

		this.addCommand(\select_voice, "i", { |msg|
			// reset currently selected voice
			voiceSynths[selectedVoice][\control].set(
				\gate, 0,
				\tip, 0,
				\palm, 0,
				\dx, 0,
				\dy, 0
				// we intentionally do NOT reset pitch, so that note doesn't change if envelope is still decaying
			);
			// select new voice
			selectedVoice = msg[1] - 1;
		});

		this.addCommand(\poll_rate, "f", { |msg|
			replySynth.set(\replyRate, msg[1]);
		});

		this.addCommand(\baseFreq, "f", { |msg|
			baseFreqBus.setSynchronous(msg[1]);
		});

		this.addCommand(\setLoop, "if", { |msg|
			voiceSynths[msg[1] - 1][\control].set(
				\loopLength, msg[2],
				\freeze, 1
			);
		});

		this.addCommand(\resetLoopPhase, "i", { |msg|
			voiceSynths[msg[1] - 1][\control].set(\loopReset, 1);
		});

		this.addCommand(\clearLoop, "i", { |msg|
			voiceSynths[msg[1] - 1][\control].set(\freeze, 0);
		});

		patchArgs.do({ |name|
			this.addCommand(name, "f", { |msg|
				patchBuses[name].set(msg[1]);
			});
		});

		modulationSources.keys.do({ |sourceName|
			modulationDests.keys.do({ |destName|
				this.addCommand(sourceName ++ '_' ++ destName, "f", { |msg|
					patchBuses[\mod][sourceName][destName].set(msg[1]);
				});
			});
		});

		this.addCommand(\gate, "i", { |msg|
			var value = msg[1];
			voiceSynths[selectedVoice][\control].set(\gate, value, \trig, value);
		});

		[ \pitch, \tip, \palm, \dx, \dy ].do({ |name|
			this.addCommand(name, "f", { |msg|
				voiceSynths[selectedVoice][\control].set(name, msg[1]);
			});
		});

		[
			\freeze,
			\loopPosition,
			\loopRate,
			\shift,
			\pan,
			\outLevel,
		].do({ |name|
			this.addCommand(name, "if", { |msg|
				voiceSynths[msg[1] - 1][\control].set(name, msg[2]);
			});
		});

		this.addCommand(\tempo, "f", { |msg|
			clockSynth.set(\rate, msg[1] / 60 / context.server.sampleRate * context.server.options.blockSize);
		});

		this.addCommand(\downbeat, "", { |msg|
			context.server.makeBundle(0.1, {
				clockSynth.set(\downbeat, 1);
			});
		});

		this.addCommand(\timbreLock, "ii", { |msg|
			this.timbreLock(msg[1] - 1, msg[2] > 0);
		});

		context.server.sync;
	}

	free {
		fork {
			sq80Resources.do(_.free);
			// d50Resources.do(_.free);
			group.free;
			clockPhaseBus.free;
			patchBuses.do(_.free);
			voiceParamBuses.do({ |dict| dict.do(_.free) });
			voiceModBuses.do({ |dict| dict.do(_.free) });
			voiceOutputBuses.do({ |dict| dict.do(_.free) });
			baseFreqBus.free;
			opFadeReplyFunc.free;
			opTypeReplyFunc.free;
			fxTypeReplyFunc.free;
			lfoTypeReplyFunc.free;
			voiceAmpReplyFunc.free;
			voicePitchReplyFunc.free;
			lfoGateReplyFunc.free;
		}
	}
}
