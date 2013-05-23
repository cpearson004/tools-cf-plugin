require "spec_helper"

describe CFTools::Watch do
  let(:fake_home_dir) { "#{SPEC_ROOT}/fixtures/fake_home_dir" }

  stub_home_dir_with { fake_home_dir }

  let(:app) { fake :app, :name => "myapp" }

  let(:client) { fake_client :apps => [app] }

  before { stub_client }

  context "when the application cannot be found" do
    it "prints a failure message" do
      cf %W[watch some-bogus-app]
      expect(error_output).to say("Unknown app 'some-bogus-app'")
    end

    it "exits with a non-zero status" do
      expect(cf %W[watch some-bogus-app]).to_not eq(0)
    end
  end

  context "when the application can be found" do
    before do
      stub(NATS).start(anything) { |_, blk| blk.call }
      stub(NATS).subscribe

      any_instance_of(described_class) do |cli|
        stub(cli).color? { true }
      end
    end

    def watch
      cf %W[watch myapp]
    end

    context "and no NATS server info is specified" do
      it "connects on nats:nats@localhost:4222" do
        mock(NATS).start(hash_including(
          :uri => "nats://nats:nats@localhost:4222"))

        watch
      end
    end

    context "and NATS server info is specified" do
      it "connects to the given location using the given credentials" do
        mock(NATS).start(hash_including(
          :uri => "nats://someuser:somepass@example.com:4242"))

        cf %W[watch myapp -h example.com -P 4242 -u someuser -p somepass]
      end
    end

    it "subscribes all messages on NATS" do
      mock(NATS).subscribe(">")
      watch
    end

    context "when a malformed message comes in" do
      it "prints an error message and keeps on truckin'" do
        stub(NATS).subscribe(">") do |_, block|
          block.call("foo-#{app.guid}", nil, "some.subject")
        end

        any_instance_of described_class do |cli|
          stub(cli).process_message { raise "hell" }
        end

        watch

        expect(output).to say(
          "couldn't deal w/ some.subject 'foo-#{app.guid}': RuntimeError: hell")
      end
    end

    context "when a message comes in with a reply channel, followed by a reply" do
      it "registers it in #requests" do
        stub(NATS).subscribe(">") do |_, block|
          block.call("foo-#{app.guid}", "some-reply", "some.subject")
          block.call("some-response", nil, "some-reply")
        end

        watch

        expect(output).to say("some.subject             (1)\tfoo-#{app.guid}")
        expect(output).to say("`- reply to some.subject (1)\tsome-response")
      end
    end

    context "when a message containing the app's GUID is seen" do
      around { |example| Timecop.freeze(&example) }

      it "prints a timestamp, message, and raw body" do
        stub(NATS).subscribe(">") do |_, block|
          block.call("some-message-mentioning-#{app.guid}", nil, "some.subject")
        end

        watch

        expect(output).to say(/#{Time.now.strftime("%r")}\s*some.subject\s*some-message-mentioning-#{app.guid}/)
      end

      context "and the subject is droplet.exited" do
        let(:payload) { <<PAYLOAD }
{
  "exit_description": "",
  "exit_status": -1,
  "reason": "STOPPED",
  "index": 0,
  "instance": "2e2b8ca31e87dd3a26cee0ddba01e84e",
  "version": "aaca113b-3ff9-4c04-8e69-28f8dc9d8cc0",
  "droplet": "#{app.guid}",
  "cc_partition": "default"
}
PAYLOAD

        it "pretty-prints the message body" do
          stub(NATS).subscribe(">") do |_, block|
            block.call(payload, nil, "droplet.exited")
          end

          watch

          expect(output).to say("reason: STOPPED, index: 0")
        end
      end

      context "and the subject is dea.heartbeat" do
        let(:payload) { <<PAYLOAD }
{
  "prod": false,
  "dea": "1-4b293b726167fbc895af5a7927c0973a",
  "droplets": [
    {
      "state_timestamp": 1369251231.3436642,
      "state": "RUNNING",
      "index": 0,
      "instance": "some app instance",
      "version": "5c0e0e10-8384-4a35-915e-872fe91ffb95",
      "droplet": "#{app.guid}",
      "cc_partition": "default"
    },
    {
      "state_timestamp": 1369251231.3436642,
      "state": "CRASHED",
      "index": 1,
      "instance": "some other app instance",
      "version": "5c0e0e10-8384-4a35-915e-872fe91ffb95",
      "droplet": "#{app.guid}",
      "cc_partition": "default"
    },
    {
      "state_timestamp": 1369251225.2800167,
      "state": "RUNNING",
      "index": 0,
      "instance": "some other other app instance",
      "version": "bdc3b7d7-5a55-455d-ac66-ba82a9ad43e7",
      "droplet": "eaebd610-0e15-4935-9784-b676d7d8495e",
      "cc_partition": "default"
    }
  ]
}
PAYLOAD

        it "prints only the application's entry" do
          stub(NATS).subscribe(">") do |_, block|
            block.call(payload, nil, "dea.heartbeat")
          end

          watch

          expect(output).to say("dea: 1, running: 1, crashed: 1")
        end
      end

      context "and the subject is dea.advertise" do
        it "prints nothing" do
          stub(NATS).subscribe(">") do |_, block|
            block.call("whatever-#{app.guid}", nil, "dea.advertise")
          end

          watch

          expect(output).to_not say("dea.advertise")
        end
      end

      context "and the subject is router.register" do
        let(:payload) { <<PAYLOAD }
{
  "private_instance_id": "e4a5ee2330c81fd7611eba7dbedbb499a00ae1b79f97f40a3603c8bff6fbcc6f",
  "tags": {},
  "port": 61111,
  "host": "192.0.43.10",
  "uris": [
    "my-app.com",
    "my-app-2.com"
  ],
  "app": "#{app.guid}",
  "dea": "1-4b293b726167fbc895af5a7927c0973a"
}
PAYLOAD
        it "prints the uris, host, and port" do
          stub(NATS).subscribe(">") do |_, block|
            block.call(payload, nil, "router.register")
          end

          watch

          expect(output).to say("dea: 1, uris: my-app.com, my-app-2.com, host: 192.0.43.10, port: 61111")
        end
      end

      context "and the subject is router.unregister" do
        let(:payload) { <<PAYLOAD }
{
  "private_instance_id": "9ade4a089b26c3aa179edec08db65f47c8379ba2c4f4da625d5180ca97c3ef04",
  "tags": {},
  "port": 61111,
  "host": "192.0.43.10",
  "uris": [
    "my-app.com"
  ],
  "app": "#{app.guid}",
  "dea": "5-029eb34eef489818abbc08413e4a70d9"
}
PAYLOAD

        it "prints the uris, host, and port" do
          stub(NATS).subscribe(">") do |_, block|
            block.call(payload, nil, "router.unregister")
          end

          watch

          expect(output).to say("dea: 5, uris: my-app.com, host: 192.0.43.10, port: 61111")
        end
      end

      context "and the subject is dea.*.start" do
        let(:payload) { <<PAYLOAD }
{
  "index": 2,
  "debug": null,
  "console": true,
  "env": [],
  "cc_partition": "default",
  "limits": {
    "fds": 16384,
    "disk": 1024,
    "mem": 128
  },
  "services": [],
  "droplet": "#{app.guid}",
  "name": "hello-sinatra",
  "uris": [
    "myapp.com"
  ],
  "prod": false,
  "sha1": "9c8f36ee81b535a7d9b4efcd9d629e8cf8a2645f",
  "executableFile": "deprecated",
  "executableUri": "https://a1-cf-app-com-cc-droplets.s3.amazonaws.com/ac/cf/accf1078-e7e1-439a-bd32-77296390c406?AWSAccessKeyId=AKIAIMGCF7E5F6M5RV3A&Signature=1lyIotK3cZ2VUyK3H8YrlT82B8c%3D&Expires=1369259081",
  "version": "ce1da6af-59b1-4fea-9e39-64c19440a671"
}
PAYLOAD

        it "filters the uuid from the subject" do
          stub(NATS).subscribe(">") do |_, block|
            block.call(payload, nil, "dea.42-deadbeef.start")
          end

          watch

          expect(output).to say("dea.42.start")
        end

        it "prints the uris, host, and port" do
          stub(NATS).subscribe(">") do |_, block|
            block.call(payload, nil, "dea.42-deadbeef.start")
          end

          watch

          expect(output).to say("dea: 42, index: 2, uris: myapp.com")
        end
      end

      context "and the subject is droplet.updated" do
        let(:payload) { <<PAYLOAD }
{
  "cc_partition": "default",
  "droplet": "#{app.guid}"
}

PAYLOAD

        it "prints a blank message" do
          stub(NATS).subscribe(">") do |_, block|
            block.call(payload, nil, "droplet.updated")
          end

          watch

          expect(output).to say("droplet.updated")
          expect(output).to_not say("cc_partition")
        end
      end

      context "and the subject is dea.stop" do
        context "and it's stopping particular indices" do
          let(:payload) { <<PAYLOAD }
{
  "indices": [
    1,
    2
  ],
  "version": "ce1da6af-59b1-4fea-9e39-64c19440a671",
  "droplet": "#{app.guid}"
}
PAYLOAD

          it "prints that it's scaling down, and the affected indices" do
            stub(NATS).subscribe(">") do |_, block|
              block.call(payload, nil, "dea.stop")
            end

            watch

            expect(output).to say("scaling down indices: 1, 2")
          end
        end

        context "when it's specifying instances (i.e. from HM)" do
          let(:payload) { <<PAYLOAD }
{
  "instances": [
    "a",
    "b",
    "c"
  ],
  "droplet": "#{app.guid}"
}
PAYLOAD
          it "prints that it's killing extra instances" do
            stub(NATS).subscribe(">") do |_, block|
              block.call(payload, nil, "dea.stop")
            end

            watch

            expect(output).to say("killing extra instances: a, b, c")
          end
        end

        context "when it's stopping the entire application" do
          let(:payload) { <<PAYLOAD }
{
  "droplet": "#{app.guid}"
}
PAYLOAD

          it "prints that it's killing extra instances" do
            stub(NATS).subscribe(">") do |_, block|
              block.call(payload, nil, "dea.stop")
            end

            watch

            expect(output).to say("stopping application")
          end
        end
      end

      context "and the subject is dea.update" do
        let(:payload) { <<PAYLOAD }
{
  "uris": [
    "myapp.com",
    "myotherroute.com"
  ],
  "droplet": "#{app.guid}"
}
PAYLOAD

        it "prints the index being stopped" do
          stub(NATS).subscribe(">") do |_, block|
            block.call(payload, nil, "dea.update")
          end

          watch

          expect(output).to say("uris: myapp.com, myotherroute.com")
        end
      end

      context "and the subject is dea.find.droplet" do
        let(:payload) { <<PAYLOAD }
{
  "version": "878318bf-64a0-4055-b79b-46871292ceb8",
  "states": [
    "STARTING",
    "RUNNING"
  ],
  "droplet": "#{app.guid}"
}
PAYLOAD

        let(:response_payload) { <<PAYLOAD }
{
  "console_port": 61016,
  "console_ip": "10.10.17.1",
  "staged": "/7cc4f4fe64c7a0fbfaacf71e9e222a35",
  "credentials": [
    "8a3890704d0d08e7bc291a0d11801c4e",
    "ba7e9e6d09170c4d3e794033fa76be97"
  ],
  "dea": "1-c0d2928b36c524153cdc8cfb51d80f75",
  "droplet": "c6c88a01-f502-4a3d-8410-b1e1e66f8c1f",
  "version": "c75b3e45-0cf4-403d-a54d-1c0970dca50d",
  "instance": "7cc4f4fe64c7a0fbfaacf71e9e222a35",
  "index": 0,
  "state": "RUNNING",
  "state_timestamp": 1369262704.3337305,
  "file_uri": "http://10.10.17.1:12345/instances"
}
PAYLOAD

        it "prints the states being queried" do
          stub(NATS).subscribe(">") do |_, block|
            block.call(payload, nil, "dea.find.droplet")
          end

          watch

          expect(output).to say("states: starting, running")
        end

        context "and we see the response" do
          it "pretty-prints the response" do
            stub(NATS).subscribe(">") do |_, block|
              block.call(payload, "some-inbox", "dea.find.droplet")
              block.call(response_payload, nil, "some-inbox")
            end

            watch

            expect(output).to say("querying states: starting, running")
            expect(output).to say("reply to dea.find.droplet (1)\tdea: 1, index: 0, state: running, since: 2013-05-22 15:45:04 -0700")
          end
        end
      end

      context "and the subject is healthmanager.status" do
        let(:payload) { <<PAYLOAD }
{
  "version": "50512eed-674e-4991-9ada-a583633c0cd4",
  "state": "FLAPPING",
  "droplet": "#{app.guid}"
}
PAYLOAD

        let(:response_payload) { <<PAYLOAD }
{
  "indices": [
    1,
    2
  ]
}
PAYLOAD

        it "prints the states being queries" do
          stub(NATS).subscribe(">") do |_, block|
            block.call(payload, nil, "healthmanager.status")
          end

          watch

          expect(output).to say("querying states: flapping")
        end

        context "and we see the response" do
          it "pretty-prints the response" do
            stub(NATS).subscribe(">") do |_, block|
              block.call(payload, "some-inbox", "healthmanager.status")
              block.call(response_payload, nil, "some-inbox")
            end

            watch

            expect(output).to say("querying states: flapping")
            expect(output).to say("reply to healthmanager.status (1)\tindices: 1, 2")
          end
        end
      end
    end

    context "when a message NOT containing the app's GUID is seen" do
      it "does not print it" do
        stub(NATS).subscribe(">") do |_, block|
          block.call("some-irrelevant-message", nil, "some.subject")
        end

        cf %W[watch myapp]

        expect(output).to_not say("some.subject")
      end
    end
  end
end
