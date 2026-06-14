import atexit
import os
import tempfile
import yaml

from ament_index_python.packages import get_package_share_directory
from launch import LaunchDescription
from launch.actions import DeclareLaunchArgument, IncludeLaunchDescription, OpaqueFunction
from launch.launch_description_sources import PythonLaunchDescriptionSource
from launch.substitutions import LaunchConfiguration

# Temp file written when ros_params is present in the config; cleaned up on exit.
_tmp_params_path = None


def _cleanup_tmp():
    if _tmp_params_path and os.path.exists(_tmp_params_path):
        os.unlink(_tmp_params_path)


def launch_setup(context, *args, **kwargs):
    global _tmp_params_path

    config_path = LaunchConfiguration('config_path').perform(context)

    with open(config_path, 'r', encoding='utf-8') as f:
        config = yaml.safe_load(f)

    launch_cfg = config.get('launch', {})
    ros_params = config.get('ros_params')

    # Convert all values to strings — the launch system requires string arguments.
    # Booleans become "true"/"false" to match what zed_camera.launch.py expects.
    launch_args = {
        k: str(v).lower() if isinstance(v, bool) else str(v)
        for k, v in launch_cfg.items()
    }

    # Write the ros_params section to a temp file and pass it as ros_params_override_path.
    # This is the highest-priority override layer in zed_camera.launch.py.
    if ros_params:
        fd, _tmp_params_path = tempfile.mkstemp(suffix='.yaml', prefix='orx_zed_params_')
        atexit.register(_cleanup_tmp)
        with os.fdopen(fd, 'w') as f:
            yaml.dump(ros_params, f, default_flow_style=False)
        launch_args['ros_params_override_path'] = _tmp_params_path

    zed_launch_path = os.path.join(
        get_package_share_directory('zed_wrapper'),
        'launch',
        'zed_camera.launch.py'
    )

    return [
        IncludeLaunchDescription(
            PythonLaunchDescriptionSource(zed_launch_path),
            launch_arguments=launch_args.items()
        )
    ]


def generate_launch_description():
    default_config = os.path.join('/workspaces/isaac_ros-dev', 'orx_zed_config.yaml')

    return LaunchDescription([
        DeclareLaunchArgument(
            'config_path',
            default_value=default_config,
            description='Path to the ORX ZED configuration YAML file. '
                        'Defaults to orx_zed_config.yaml at the workspace root.'
        ),
        OpaqueFunction(function=launch_setup)
    ])
