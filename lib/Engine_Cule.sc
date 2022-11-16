Engine_Cule : CroneEngine {

	// TODO: replace or augment buses with buffers
	// var ampBus;
	// var freqBus;
	var synth;

	*new { arg context, doneCallback;
		^super.new(context, doneCallback);
	}

	alloc {

		// ampBus = Bus.control(context.server);
		// freqBus = Bus.control(context.server);

		SynthDef.new(\line, {

			// TODO:
			// - base freq and linear, CV-style pitch
			// - mod matrix instead of direct amp control
			arg pitch = 0,
				pitchSlew = 0.01,
				baseFreq = 60.midicps,
				octave = 0,
				fb = 0,
				fold = 0.3,
				amp = 0,
				lag = 0.1;

			var hz, sine, folded;

			// TODO: why can't I use MovingAverage.kr here to get a linear slew?!
			// if I try that, SC seems to just hang forever, no error message
			pitch = Lag.kr(pitch, pitchSlew);
			hz = 2.pow(pitch + octave) * baseFreq;

			amp  = Lag.kr(amp, lag);
			fb   = Lag.kr(fb, lag);
			fold = Lag.kr(fold, lag);

			sine = SinOscFB.ar(hz, fb);
			folded = SinOsc.ar(0, pi * fold * sine) * amp;

			Out.ar(context.out_b, folded ! 2);
		}).add;

		context.server.sync;

		synth = Synth.new(\line, [
			\in_l, context.in_b[0],
			\in_r, context.in_b[1]
		], context.og); // "output" group

		this.addCommand(\pitch, "f", {
			arg msg;
			synth.set(\pitch, msg[1]);
		});

		this.addCommand(\pitch_slew, "f", {
			arg msg;
			synth.set(\pitchSlew, msg[1]);
		});

		this.addCommand(\base_freq, "f", {
			arg msg;
			synth.set(\baseFreq, msg[1]);
		});

		this.addCommand(\amp, "f", {
			arg msg;
			synth.set(\amp, msg[1]);
		});

		this.addCommand(\amplag, "f", {
			arg msg;
			synth.set(\amplag, msg[1]);
		});

		this.addCommand(\fb, "f", {
			arg msg;
			synth.set(\fb, msg[1]);
		});

		this.addCommand(\fold, "f", {
			arg msg;
			synth.set(\fold, msg[1]);
		});

		this.addCommand(\octave, "i", {
			arg msg;
			synth.set(\octave, msg[1]);
		});
	}

	free {
		synth.free;
		// ampBus.free;
		// freqBus.free;
	}
}
