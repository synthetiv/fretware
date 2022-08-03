Engine_Analyst : CroneEngine {

	var ampBus;
	var freqBus;
	var clarityBus;
	var synth;

	*new { arg context, doneCallback;
		^super.new(context, doneCallback);
	}

	alloc {

		var cFreq = 60.midicps;

		ampBus = Bus.control(context.server);
		freqBus = Bus.control(context.server);
		clarityBus = Bus.control(context.server);

		SynthDef.new(\analyst, {
			arg in_l, in_r,
				pitchAmpThreshold = 0.01,
				pitchPeakThreshold = 0.5,
				pitchClarityThreshold = 0.3;
			var input, amp, freq, clarity;
			input = In.ar([in_l, in_r]).sum / 2;
			amp = Amplitude.kr(input);
			# freq, clarity = Pitch.kr(
				input,
				initFreq: cFreq,
				minFreq: 30,
				ampThreshold: pitchAmpThreshold,
				peakThresold: pitchPeakThreshold,
				clar: 1
			);
			Out.kr(ampBus, amp);
			Out.kr(freqBus, freq);
			Out.kr(clarityBus, clarity);
		}).add;

		context.server.sync;

		synth = Synth.new(\analyst, [
			\in_l, context.in_b[0],
			\in_r, context.in_b[1]
		], context.xg); // "process" group

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

		this.addPoll(\amp, {
			ampBus.getSynchronous;
		});

		this.addPoll(\freq, {
			freqBus.getSynchronous;
		});

		this.addPoll(\pitch, {
			(freqBus.getSynchronous / cFreq).log2;
		});

		this.addPoll(\clarity, {
			clarityBus.getSynchronous;
		});
	}

	free {
		synth.free;
		ampBus.free;
		freqBus.free;
		clarityBus.free;
	}
}
