Engine_Analyst : CroneEngine {

	var zeroCrossingBus;
	var pitchBus;
	var tartiniBus;
	var synth;

	*new { arg context, doneCallback;
		^super.new(context, doneCallback);
	}

	alloc {

		var cFreq = 60.midicps;

		zeroCrossingBus = Bus.control(context.server);
		pitchBus = Bus.control(context.server);
		tartiniBus = Bus.control(context.server);

		SynthDef.new(\analyst, {
			arg in_l, in_r, // out,
				zeroCrossingAmpThreshold = 0.3,
				pitchAmpThreshold = 0.01,
				pitchPeakThreshold = 0.5,
				pitchClarityThreshold = 0.3,
				tartiniThreshold = 0.93,
				tartiniClarityThreshold = 0.3;
			var input, zeroCrossingFreq, amp, pitchFreq, pitchHasFreq, tartiniFreq, tartiniHasFreq;
			input = In.ar([in_l, in_r]).sum / 2;
			zeroCrossingFreq = ZeroCrossing.ar(input);
			amp = Amplitude.kr(input);
			# pitchFreq, pitchHasFreq = Pitch.kr(
				input,
				initFreq: cFreq,
				minFreq: 30,
				ampThreshold: pitchAmpThreshold,
				peakThresold: pitchPeakThreshold,
				clar: 1
			);
			# tartiniFreq, tartiniHasFreq = Tartini.kr(
				input,
				threshold: tartiniThreshold
			);
			Out.kr(zeroCrossingBus, Gate.kr(A2K.kr(zeroCrossingFreq), amp > zeroCrossingAmpThreshold));
			Out.kr(pitchBus, Gate.kr(pitchFreq, pitchHasFreq > pitchClarityThreshold));
			Out.kr(tartiniBus, Gate.kr(tartiniFreq, tartiniHasFreq > tartiniClarityThreshold));
			/*
			Out.kr(out, [
				,
				amp,
				,
				pitchHasFreq,
				,
				tartiniHasFreq
			]);
			*/
		}).add;

		context.server.sync;

		synth = Synth.new(\analyst, [
			\in_l, context.in_b[0],
			\in_r, context.in_b[1]
		], context.xg); // "process" group

		this.addCommand(\zero_crossing_amp_threshold, "f", {
			arg msg;
			synth.set(\zeroCrossingAmpThreshold, msg[1]);
		});

		this.addCommand(\pitch_amp_threshold, "f", {
			arg msg;
			synth.set(\pitchAmpThreshold, msg[1]);
		});

		this.addCommand(\pitch_peak_threshold, "f", {
			arg msg;
			synth.set(\pitchPeakThreshold, msg[1]);
		});

		this.addCommand(\pitch_clarity_threshold, "f", {
			arg msg;
			synth.set(\pitchClarityThreshold, msg[1]);
		});

		this.addCommand(\tartini_threshold, "f", {
			arg msg;
			synth.set(\tartiniThreshold, msg[1]);
		});

		this.addCommand(\tartini_clarity_threshold, "f", {
			arg msg;
			synth.set(\tartiniClarityThreshold, msg[1]);
		});

		this.addPoll(\zero_crossing_pitch, {
			(zeroCrossingBus.getSynchronous / cFreq).log2;
		});

		// this.addPoll(\amp, {
		// 	bus[1].getSynchronous;
		// });

		this.addPoll(\pitch_pitch, {
			(pitchBus.getSynchronous / cFreq).log2;
		});

		// this.addPoll(\pitch_clarity, {
		// 	bus[3].getSynchronous;
		// });

		this.addPoll(\tartini_pitch, {
			(tartiniBus.getSynchronous / cFreq).log2;
		});

		// this.addPoll(\tartini_clarity, {
		// 	bus[5].getSynchronous;
		// });
	}

	free {
		synth.free;
		zeroCrossingBus.free;
		pitchBus.free;
		tartiniBus.free;
	}
}
