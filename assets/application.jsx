'use strict';

class Process extends React.Component {
  hup() {
    fetch(
      `/message-bus/_diagnostics/hup/${this.props.hostname}/${this.props.pid}`,
      {
        method: 'POST'
      }
    );
  }

  render() {
    return (
      <tr>
        <td>{this.props.pid}</td>
        <td>{this.props.full_path}</td>
        <td>{this.props.hostname}</td>
        <td>{this.props.uptime} secs</td>
        <td><button onClick={this.hup.bind(this)}>HUP</button></td>
      </tr>
    );
  }
};

class DiagnosticsApp extends React.Component {
  constructor(props) {
    super(props);
    this.state = {processes: []};
  }

  componentDidMount() {
    MessageBus.start();
    this.ensureSubscribed();
  }

  discover() {
    this.ensureSubscribed();

    this.setState({discovering: true});

    var _this = this;
    fetch(
      "/message-bus/_diagnostics/discover",
      {
        method: "POST"
      }
    ).then(function() {
      _this.setState({discovering: false})
    });
  }

  ensureSubscribed() {
    if (this.state.subscribed) { return; }

    MessageBus.callbackInterval = 500;

    MessageBus.subscribe(
      "/_diagnostics/process-discovery",
      this.updateProcess.bind(this)
    );

    this.setState({subscribed: true});
  }

  updateProcess(data) {
    const _this = this;
    const processes = this.state.processes.filter(function(process) {
      return _this.processUniqueId(process) !== _this.processUniqueId(data);
    });
    this.setState({processes: processes.concat([data])});
  }

  processUniqueId(process) {
    return process.hostname + process.pid;
  }

  render() {
    let disabled = this.state.discovering ? "disabled" : null;

    let _this = this;
    let processes = this.state.processes.sort(function(a,b) {
      return _this.processUniqueId(a) < _this.processUniqueId(b) ? -1 : 1;
    });

    return (
      <div>
        <header>
          <h2>Message Bus Diagnostics</h2>
        </header>

        <div>
          <button onClick={this.discover.bind(this)} disabled={disabled}>Discover Processes</button>

          <table>
            <thead>
              <tr>
                <td>pid</td>
                <td>full_path</td>
                <td>hostname</td>
                <td>uptime</td>
                <td></td>
              </tr>
            </thead>

            <tbody>
              {processes.map(function(process, index){
                return <Process key={index} {...process} />;
              })}
            </tbody>
          </table>
        </div>
      </div>
    );
  }
}

ReactDOM.render(
  <DiagnosticsApp />,
  document.getElementById('app')
);
