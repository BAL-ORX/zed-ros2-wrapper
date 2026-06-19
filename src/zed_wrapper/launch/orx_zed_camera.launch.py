import atexit
import os
import tempfile
import yaml

from ament_index_python.packages import get_package_share_directory
from launch import LaunchDescription
from launch.actions import DeclareLaunchArgument, IncludeLaunchDescription, OpaqueFunction
from launch.launch_description_sources import PythonLaunchDescriptionSource
from launch.substitutions import LaunchConfiguration
from launch_ros.actions import LoadComposableNodes
from launch_ros.descriptions import ComposableNode

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
    encoder_cfg = config.get('encoder', {})

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

    actions = [
        IncludeLaunchDescription(
            PythonLaunchDescriptionSource(zed_launch_path),
            launch_arguments=launch_args.items()
        )
    ]

    # ── Optional H264 encoder via NITROS zero-copy IPC ─────────────────────
    # Loads EncoderNodes into the same ComposableNodeContainer as the ZED node.
    # NITROS negotiates zero-copy transport automatically when nodes share a process.
    # Requires debug.disable_nitros: false in ros_params (NITROS must be active).
    if encoder_cfg.get('enabled', False):
        camera_name = launch_cfg.get('camera_name', 'zed')
        namespace = launch_cfg.get('namespace', '') or camera_name
        node_name = launch_cfg.get('node_name', 'zed_node')
        # zed_camera.launch.py uses 'zed_container' when container_name is empty
        container_name = launch_cfg.get('container_name', '') or 'zed_container'
        target_container = f'/{namespace}/{container_name}'

        encoder_params = {
            'input_width': int(encoder_cfg.get('input_width', 1920)),
            'input_height': int(encoder_cfg.get('input_height', 1080)),
            'qp': int(encoder_cfg.get('qp', 20)),
            'hw_preset_type': int(encoder_cfg.get('hw_preset_type', 0)),
            'profile': int(encoder_cfg.get('profile', 0)),
            'iframe_interval': int(encoder_cfg.get('iframe_interval', 5)),
            'config': str(encoder_cfg.get('config', 'pframe_cqp')),
        }

        encoder_nodes = []

        input_left = encoder_cfg.get('input_left', 'left/color/rect/image')
        if input_left:
            output_left = encoder_cfg.get('output_left', 'left/image_compressed')
            encoder_nodes.append(ComposableNode(
                package='isaac_ros_h264_encoder',
                plugin='nvidia::isaac_ros::h264_encoder::EncoderNode',
                name='left_encoder_node',
                namespace=namespace,
                parameters=[encoder_params],
                remappings=[
                    ('image_raw', f'/{namespace}/{node_name}/{input_left}'),
                    ('image_compressed', f'/{namespace}/{output_left}'),
                ],
            ))

        input_right = encoder_cfg.get('input_right', 'right/color/rect/image')
        if input_right:
            output_right = encoder_cfg.get('output_right', 'right/image_compressed')
            encoder_nodes.append(ComposableNode(
                package='isaac_ros_h264_encoder',
                plugin='nvidia::isaac_ros::h264_encoder::EncoderNode',
                name='right_encoder_node',
                namespace=namespace,
                parameters=[encoder_params],
                remappings=[
                    ('image_raw', f'/{namespace}/{node_name}/{input_right}'),
                    ('image_compressed', f'/{namespace}/{output_right}'),
                ],
            ))

        if encoder_nodes:
            actions.append(LoadComposableNodes(
                composable_node_descriptions=encoder_nodes,
                target_container=target_container,
            ))

    return actions


def generate_launch_description():
    default_config = os.path.join('/workspaces/isaac_ros-dev', 'config_orx.yaml')

    return LaunchDescription([
        DeclareLaunchArgument(
            'config_path',
            default_value=default_config,
            description='Path to the ORX ZED configuration YAML file. '
                        'Defaults to config_orx.yaml at the workspace root.'
        ),
        OpaqueFunction(function=launch_setup)
    ])
