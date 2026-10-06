/*
Synapse's native Vulkan graph renderer.

The Vulkan/GLFW setup is adapted from the Odin examples triangle by laytan:
https://github.com/odin-lang/examples/tree/master/vulkan/triangle_glfw
*/
package main

import "base:runtime"

import "core:fmt"
import "core:log"
import "core:math"
import "core:mem"
import "core:os"
import "core:slice"
import "core:strings"
import "core:time"


import "vendor:glfw"
import vk "vendor:vulkan"

when ODIN_OS == .Darwin {
	// NOTE: just a bogus import of the system library,
	// needed so we can add a linker flag to point to /usr/local/lib (where vulkan is installed by default)
	// when trying to load vulkan.
	@(require, extra_linker_flags = "-rpath /usr/local/lib")
	foreign import __ "system:System.framework"
}

SHADER_VERT :: #load("vert.spv")
SHADER_FRAG :: #load("frag.spv")

// Enables Vulkan debug logging and validation layers.
ENABLE_VALIDATION_LAYERS :: #config(ENABLE_VALIDATION_LAYERS, false)

MAX_FRAMES_IN_FLIGHT :: 2

g_ctx: runtime.Context

g_window: glfw.WindowHandle

g_framebuffer_resized: bool

g_graph: Graph
g_vertices: [dynamic]Vertex
g_vertex_buffer: vk.Buffer
g_vertex_memory: vk.DeviceMemory
g_zoom: f32 = 1.0
g_pan := Vec2{}
g_last_hovered := -2
g_root: string
g_current: string
g_vault_fingerprint: u64
g_next_vault_scan: f64
g_theme_file: string
g_next_theme_scan: f64
g_background := [4]f32{0.025, 0.035, 0.055, 1.0}
g_node_color := [4]f32{0.30, 0.68, 0.96, 1.0}
g_edge_color := [4]f32{0.35, 0.48, 0.68, 0.42}
g_muted_color := [4]f32{0.43, 0.48, 0.58, 1.0}
g_highlight_color := [4]f32{1.0, 0.70, 0.22, 1.0}

Vertex :: struct {
	x, y:       f32,
	r, g, b, a: f32,
}

Push_Constants :: struct {
	pan_x, pan_y: f32,
	zoom, aspect: f32,
}

g_instance: vk.Instance
g_physical_device: vk.PhysicalDevice
g_device: vk.Device
g_surface: vk.SurfaceKHR
g_graphics_queue: vk.Queue
g_present_queue: vk.Queue

g_swapchain: vk.SwapchainKHR
g_swapchain_images: []vk.Image
g_swapchain_views: []vk.ImageView
g_swapchain_format: vk.SurfaceFormatKHR
g_swapchain_extent: vk.Extent2D
g_swapchain_frame_buffers: []vk.Framebuffer

g_vert_shader_module: vk.ShaderModule
g_frag_shader_module: vk.ShaderModule
g_shader_stages: [2]vk.PipelineShaderStageCreateInfo

g_render_pass: vk.RenderPass
g_pipeline_layout: vk.PipelineLayout
g_pipeline: vk.Pipeline

g_command_pool: vk.CommandPool
g_command_buffers: [MAX_FRAMES_IN_FLIGHT]vk.CommandBuffer

g_image_available_semaphores: [MAX_FRAMES_IN_FLIGHT]vk.Semaphore
g_render_finished_semaphores: [MAX_FRAMES_IN_FLIGHT]vk.Semaphore
g_in_flight_fences: [MAX_FRAMES_IN_FLIGHT]vk.Fence

// KHR_PORTABILITY_SUBSET_EXTENSION_NAME :: "VK_KHR_portability_subset"

DEVICE_EXTENSIONS := []cstring {
	vk.KHR_SWAPCHAIN_EXTENSION_NAME,
	// KHR_PORTABILITY_SUBSET_EXTENSION_NAME,
}

main :: proc() {
	context.logger = log.create_console_logger()
	g_ctx = context

	g_root, g_current, g_theme_file = parse_arguments()
	load_theme(g_theme_file)
	ok: bool
	g_graph, ok = load_graph(g_root)
	if !ok { log.panicf("could not scan vault %q", g_root) }
	layout_graph(&g_graph)
	g_vertices = build_mesh(&g_graph, g_current)
	g_vault_fingerprint = vault_fingerprint(g_root)
	log.infof("synapse: loaded %d notes and %d links", len(g_graph.notes), len(g_graph.edges))

	// TODO: update vendor bindings to glfw 3.4 and use this to set a custom allocator.
	// glfw.InitAllocator()

	// TODO: set up Vulkan allocator.

	glfw.SetErrorCallback(glfw_error_callback)

	if !glfw.Init() {log.panic("glfw: could not be initialized")}
	defer glfw.Terminate()

	glfw.WindowHint(glfw.CLIENT_API, glfw.NO_API)
	glfw.WindowHint(glfw.RESIZABLE, glfw.TRUE)

	title := fmt.aprintf("Synapse — %d notes · %d links", len(g_graph.notes), len(g_graph.edges))
	defer delete(title)
	c_title := strings.clone_to_cstring(title)
	g_window = glfw.CreateWindow(1100, 760, c_title, nil, nil)
	delete(c_title)
	if g_window == nil { log.panic("glfw: could not create a Vulkan window") }
	defer glfw.DestroyWindow(g_window)
	glfw.SetScrollCallback(g_window, scroll_callback)

	glfw.SetFramebufferSizeCallback(g_window, proc "c" (_: glfw.WindowHandle, _, _: i32) {
		g_framebuffer_resized = true
	})

	vk.load_proc_addresses_global(rawptr(glfw.GetInstanceProcAddress))
	assert(vk.CreateInstance != nil, "vulkan function pointers not loaded")

	create_info := vk.InstanceCreateInfo {
		sType            = .INSTANCE_CREATE_INFO,
		pApplicationInfo = &vk.ApplicationInfo {
			sType = .APPLICATION_INFO,
			pApplicationName = "Synapse",
			applicationVersion = vk.MAKE_VERSION(1, 0, 0),
			pEngineName = "No Engine",
			engineVersion = vk.MAKE_VERSION(1, 0, 0),
			apiVersion = vk.API_VERSION_1_0,
		},
	}

	extensions := slice.clone_to_dynamic(glfw.GetRequiredInstanceExtensions(), context.temp_allocator)

	// MacOS is a special snowflake ;)
	when ODIN_OS == .Darwin {
		create_info.flags |= {.ENUMERATE_PORTABILITY_KHR}
		append(&extensions, vk.KHR_PORTABILITY_ENUMERATION_EXTENSION_NAME)
	}

	when ENABLE_VALIDATION_LAYERS {
		create_info.ppEnabledLayerNames = raw_data([]cstring{"VK_LAYER_KHRONOS_validation"})
		create_info.enabledLayerCount = 1

		append(&extensions, vk.EXT_DEBUG_UTILS_EXTENSION_NAME)

		// Severity based on logger level.
		severity: vk.DebugUtilsMessageSeverityFlagsEXT
		if context.logger.lowest_level <= .Error {
			severity |= {.ERROR}
		}
		if context.logger.lowest_level <= .Warning {
			severity |= {.WARNING}
		}
		if context.logger.lowest_level <= .Info {
			severity |= {.INFO}
		}
		if context.logger.lowest_level <= .Debug {
			severity |= {.VERBOSE}
		}

		dbg_create_info := vk.DebugUtilsMessengerCreateInfoEXT {
			sType           = .DEBUG_UTILS_MESSENGER_CREATE_INFO_EXT,
			messageSeverity = severity,
			messageType     = {.GENERAL, .VALIDATION, .PERFORMANCE, .DEVICE_ADDRESS_BINDING}, // all of them.
			pfnUserCallback = vk_messenger_callback,
		}
		create_info.pNext = &dbg_create_info
	}

	create_info.enabledExtensionCount = u32(len(extensions))
	create_info.ppEnabledExtensionNames = raw_data(extensions)

	must(vk.CreateInstance(&create_info, nil, &g_instance))
	defer vk.DestroyInstance(g_instance, nil)

	vk.load_proc_addresses_instance(g_instance)

	when ENABLE_VALIDATION_LAYERS {
		dbg_messenger: vk.DebugUtilsMessengerEXT
		must(vk.CreateDebugUtilsMessengerEXT(g_instance, &dbg_create_info, nil, &dbg_messenger))
		defer vk.DestroyDebugUtilsMessengerEXT(g_instance, dbg_messenger, nil)
	}

	must(glfw.CreateWindowSurface(g_instance, g_window, nil, &g_surface))
	defer vk.DestroySurfaceKHR(g_instance, g_surface, nil)

	// Pick a suitable GPU.
	must(pick_physical_device())

	// Setup logical device.
	indices := find_queue_families(g_physical_device)
	{
		// TODO: this is kinda messy.
		indices_set := make(map[u32]struct {}, allocator = context.temp_allocator)
		indices_set[indices.graphics.?] = {}
		indices_set[indices.present.?] = {}

		queue_create_infos := make([dynamic]vk.DeviceQueueCreateInfo, 0, len(indices_set), context.temp_allocator)
		for family in indices_set {
			append(
				&queue_create_infos,
				vk.DeviceQueueCreateInfo {
					sType = .DEVICE_QUEUE_CREATE_INFO,
					queueFamilyIndex = family,
					queueCount = 1,
					pQueuePriorities = raw_data([]f32{1}),
				},// Scheduling priority between 0 and 1.
			)
		}

		device_create_info := vk.DeviceCreateInfo {
			sType                   = .DEVICE_CREATE_INFO,
			pQueueCreateInfos       = raw_data(queue_create_infos),
			queueCreateInfoCount    = u32(len(queue_create_infos)),
			enabledLayerCount       = create_info.enabledLayerCount,
			ppEnabledLayerNames     = create_info.ppEnabledLayerNames,
			ppEnabledExtensionNames = raw_data(DEVICE_EXTENSIONS),
			enabledExtensionCount   = u32(len(DEVICE_EXTENSIONS)),
		}

		must(vk.CreateDevice(g_physical_device, &device_create_info, nil, &g_device))

		vk.GetDeviceQueue(g_device, indices.graphics.?, 0, &g_graphics_queue)
		vk.GetDeviceQueue(g_device, indices.present.?, 0, &g_present_queue)
	}
	defer vk.DestroyDevice(g_device, nil)

	create_vertex_buffer(g_vertices[:])
	defer destroy_vertex_buffer()

	create_swapchain()
	defer destroy_swapchain()

	// Load shaders.
	{
		g_vert_shader_module = create_shader_module(SHADER_VERT)
		g_shader_stages[0] = vk.PipelineShaderStageCreateInfo {
			sType  = .PIPELINE_SHADER_STAGE_CREATE_INFO,
			stage  = {.VERTEX},
			module = g_vert_shader_module,
			pName  = "main",
		}

		g_frag_shader_module = create_shader_module(SHADER_FRAG)
		g_shader_stages[1] = vk.PipelineShaderStageCreateInfo {
			sType  = .PIPELINE_SHADER_STAGE_CREATE_INFO,
			stage  = {.FRAGMENT},
			module = g_frag_shader_module,
			pName  = "main",
		}
	}
	defer vk.DestroyShaderModule(g_device, g_vert_shader_module, nil)
	defer vk.DestroyShaderModule(g_device, g_frag_shader_module, nil)

	// Set up render pass.
	{
		color_attachment := vk.AttachmentDescription {
			format         = g_swapchain_format.format,
			samples        = {._1},
			loadOp         = .CLEAR,
			storeOp        = .STORE,
			stencilLoadOp  = .DONT_CARE,
			stencilStoreOp = .DONT_CARE,
			initialLayout  = .UNDEFINED,
			finalLayout    = .PRESENT_SRC_KHR,
		}

		color_attachment_ref := vk.AttachmentReference {
			attachment = 0,
			layout     = .COLOR_ATTACHMENT_OPTIMAL,
		}

		subpass := vk.SubpassDescription {
			pipelineBindPoint    = .GRAPHICS,
			colorAttachmentCount = 1,
			pColorAttachments    = &color_attachment_ref,
		}

		dependency := vk.SubpassDependency {
			srcSubpass    = vk.SUBPASS_EXTERNAL,
			dstSubpass    = 0,
			srcStageMask  = {.COLOR_ATTACHMENT_OUTPUT},
			srcAccessMask = {},
			dstStageMask  = {.COLOR_ATTACHMENT_OUTPUT},
			dstAccessMask = {.COLOR_ATTACHMENT_WRITE},
		}

		render_pass := vk.RenderPassCreateInfo {
			sType           = .RENDER_PASS_CREATE_INFO,
			attachmentCount = 1,
			pAttachments    = &color_attachment,
			subpassCount    = 1,
			pSubpasses      = &subpass,
			dependencyCount = 1,
			pDependencies   = &dependency,
		}

		must(vk.CreateRenderPass(g_device, &render_pass, nil, &g_render_pass))
	}
	defer vk.DestroyRenderPass(g_device, g_render_pass, nil)

	create_framebuffers()
	defer destroy_framebuffers()

	// Set up pipeline.
	{
		dynamic_states := []vk.DynamicState{.VIEWPORT, .SCISSOR}
		dynamic_state := vk.PipelineDynamicStateCreateInfo {
			sType             = .PIPELINE_DYNAMIC_STATE_CREATE_INFO,
			dynamicStateCount = 2,
			pDynamicStates    = raw_data(dynamic_states),
		}

		binding := vk.VertexInputBindingDescription {
			binding = 0,
			stride = size_of(Vertex),
			inputRate = .VERTEX,
		}
		attributes := [2]vk.VertexInputAttributeDescription {
			{location = 0, binding = 0, format = .R32G32_SFLOAT, offset = u32(offset_of(Vertex, x))},
			{location = 1, binding = 0, format = .R32G32B32A32_SFLOAT, offset = u32(offset_of(Vertex, r))},
		}
		vertex_input_info := vk.PipelineVertexInputStateCreateInfo {
			sType = .PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO,
			vertexBindingDescriptionCount = 1,
			pVertexBindingDescriptions = &binding,
			vertexAttributeDescriptionCount = 2,
			pVertexAttributeDescriptions = &attributes[0],
		}

		input_assembly := vk.PipelineInputAssemblyStateCreateInfo {
			sType    = .PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO,
			topology = .TRIANGLE_LIST,
		}

		viewport_state := vk.PipelineViewportStateCreateInfo {
			sType         = .PIPELINE_VIEWPORT_STATE_CREATE_INFO,
			viewportCount = 1,
			scissorCount  = 1,
		}

		rasterizer := vk.PipelineRasterizationStateCreateInfo {
			sType       = .PIPELINE_RASTERIZATION_STATE_CREATE_INFO,
			polygonMode = .FILL,
			lineWidth   = 1,
			cullMode    = {},
			frontFace   = .CLOCKWISE,
		}

		multisampling := vk.PipelineMultisampleStateCreateInfo {
			sType                = .PIPELINE_MULTISAMPLE_STATE_CREATE_INFO,
			rasterizationSamples = {._1},
			minSampleShading     = 1,
		}

		color_blend_attachment := vk.PipelineColorBlendAttachmentState {
			blendEnable = true,
			srcColorBlendFactor = .SRC_ALPHA,
			dstColorBlendFactor = .ONE_MINUS_SRC_ALPHA,
			colorBlendOp = .ADD,
			srcAlphaBlendFactor = .ONE,
			dstAlphaBlendFactor = .ONE_MINUS_SRC_ALPHA,
			alphaBlendOp = .ADD,
			colorWriteMask = {.R, .G, .B, .A},
		}

		color_blending := vk.PipelineColorBlendStateCreateInfo {
			sType           = .PIPELINE_COLOR_BLEND_STATE_CREATE_INFO,
			attachmentCount = 1,
			pAttachments    = &color_blend_attachment,
		}

		push_range := vk.PushConstantRange {
			stageFlags = {.VERTEX},
			offset = 0,
			size = size_of(Push_Constants),
		}
		pipeline_layout := vk.PipelineLayoutCreateInfo {
			sType = .PIPELINE_LAYOUT_CREATE_INFO,
			pushConstantRangeCount = 1,
			pPushConstantRanges = &push_range,
		}
		must(vk.CreatePipelineLayout(g_device, &pipeline_layout, nil, &g_pipeline_layout))

		pipeline := vk.GraphicsPipelineCreateInfo {
			sType               = .GRAPHICS_PIPELINE_CREATE_INFO,
			stageCount          = 2,
			pStages             = &g_shader_stages[0],
			pVertexInputState   = &vertex_input_info,
			pInputAssemblyState = &input_assembly,
			pViewportState      = &viewport_state,
			pRasterizationState = &rasterizer,
			pMultisampleState   = &multisampling,
			pColorBlendState    = &color_blending,
			pDynamicState       = &dynamic_state,
			layout              = g_pipeline_layout,
			renderPass          = g_render_pass,
			subpass             = 0,
			basePipelineIndex   = -1,
		}
		must(vk.CreateGraphicsPipelines(g_device, 0, 1, &pipeline, nil, &g_pipeline))
	}
	defer vk.DestroyPipelineLayout(g_device, g_pipeline_layout, nil)
	defer vk.DestroyPipeline(g_device, g_pipeline, nil)

	// Create command pool.
	{
		pool_info := vk.CommandPoolCreateInfo {
			sType            = .COMMAND_POOL_CREATE_INFO,
			flags            = {.RESET_COMMAND_BUFFER},
			queueFamilyIndex = indices.graphics.?,
		}
		must(vk.CreateCommandPool(g_device, &pool_info, nil, &g_command_pool))

		alloc_info := vk.CommandBufferAllocateInfo {
			sType              = .COMMAND_BUFFER_ALLOCATE_INFO,
			commandPool        = g_command_pool,
			level              = .PRIMARY,
			commandBufferCount = MAX_FRAMES_IN_FLIGHT,
		}
		must(vk.AllocateCommandBuffers(g_device, &alloc_info, &g_command_buffers[0]))
	}
	defer vk.DestroyCommandPool(g_device, g_command_pool, nil)

	// Set up sync primitives.
	{
		sem_info := vk.SemaphoreCreateInfo {
			sType = .SEMAPHORE_CREATE_INFO,
		}
		fence_info := vk.FenceCreateInfo {
			sType = .FENCE_CREATE_INFO,
			flags = {.SIGNALED},
		}
		for i in 0 ..< MAX_FRAMES_IN_FLIGHT {
			must(vk.CreateSemaphore(g_device, &sem_info, nil, &g_image_available_semaphores[i]))
			must(vk.CreateSemaphore(g_device, &sem_info, nil, &g_render_finished_semaphores[i]))
			must(vk.CreateFence(g_device, &fence_info, nil, &g_in_flight_fences[i]))
		}
	}
	defer for sem in g_image_available_semaphores {vk.DestroySemaphore(g_device, sem, nil)}
	defer for sem in g_render_finished_semaphores {vk.DestroySemaphore(g_device, sem, nil)}
	defer for fence in g_in_flight_fences {vk.DestroyFence(g_device, fence, nil)}

	current_frame := 0
	for !glfw.WindowShouldClose(g_window) {
		free_all(context.temp_allocator)

		glfw.PollEvents()
		handle_input()
		reload_graph_if_changed()
		reload_theme_if_changed()

		// Wait for previous frame.
		must(vk.WaitForFences(g_device, 1, &g_in_flight_fences[current_frame], true, max(u64)))

		// Acquire an image from the swapchain.
		image_index: u32
		acquire_result := vk.AcquireNextImageKHR(
			g_device,
			g_swapchain,
			max(u64),
			g_image_available_semaphores[current_frame],
			0,
			&image_index,
		)
		#partial switch acquire_result {
		case .ERROR_OUT_OF_DATE_KHR:
			recreate_swapchain()
			continue
		case .SUCCESS, .SUBOPTIMAL_KHR:
		case:
			log.panicf("vulkan: acquire next image failure: %v", acquire_result)
		}

		must(vk.ResetFences(g_device, 1, &g_in_flight_fences[current_frame]))

		must(vk.ResetCommandBuffer(g_command_buffers[current_frame], {}))
		record_command_buffer(g_command_buffers[current_frame], image_index)

		// Submit.
		submit_info := vk.SubmitInfo {
			sType                = .SUBMIT_INFO,
			waitSemaphoreCount   = 1,
			pWaitSemaphores      = &g_image_available_semaphores[current_frame],
			pWaitDstStageMask    = &vk.PipelineStageFlags{.COLOR_ATTACHMENT_OUTPUT},
			commandBufferCount   = 1,
			pCommandBuffers      = &g_command_buffers[current_frame],
			signalSemaphoreCount = 1,
			pSignalSemaphores    = &g_render_finished_semaphores[current_frame],
		}
		must(vk.QueueSubmit(g_graphics_queue, 1, &submit_info, g_in_flight_fences[current_frame]))

		// Present.
		present_info := vk.PresentInfoKHR {
			sType              = .PRESENT_INFO_KHR,
			waitSemaphoreCount = 1,
			pWaitSemaphores    = &g_render_finished_semaphores[current_frame],
			swapchainCount     = 1,
			pSwapchains        = &g_swapchain,
			pImageIndices      = &image_index,
		}
		present_result := vk.QueuePresentKHR(g_present_queue, &present_info)
		switch {
		case present_result == .ERROR_OUT_OF_DATE_KHR || present_result == .SUBOPTIMAL_KHR || g_framebuffer_resized:
			g_framebuffer_resized = false
			recreate_swapchain()
		case present_result == .SUCCESS:
		case:
			log.panicf("vulkan: present failure: %v", present_result)
		}

		current_frame = (current_frame + 1) % MAX_FRAMES_IN_FLIGHT
	}
	vk.DeviceWaitIdle(g_device)
}

@(require_results)
pick_physical_device :: proc() -> vk.Result {

	score_physical_device :: proc(device: vk.PhysicalDevice) -> (score: int) {
		props: vk.PhysicalDeviceProperties
		vk.GetPhysicalDeviceProperties(device, &props)

		name := byte_arr_str(&props.deviceName)
		log.infof("vulkan: evaluating device %q", name)
		defer log.infof("vulkan: device %q scored %v", name, score)

		features: vk.PhysicalDeviceFeatures
		vk.GetPhysicalDeviceFeatures(device, &features)

		// // App can't function without geometry shaders.
		// if !features.geometryShader {
		// 	log.info("vulkan: device does not support geometry shaders")
		// 	return 0
		// }

		// Need certain extensions supported.
		{
			extensions, result := physical_device_extensions(device, context.temp_allocator)
			if result != .SUCCESS {
				log.infof("vulkan: enumerate device extension properties failed: %v", result)
				return 0
			}

			required_loop: for required in DEVICE_EXTENSIONS {
				for &extension in extensions {
					extension_name := byte_arr_str(&extension.extensionName)
					if extension_name == string(required) {
						continue required_loop
					}
				}

				log.infof("vulkan: device does not support required extension %q", required)
				return 0
			}
		}

		// Check if swapchain is adequately supported.
		{
			support, result := query_swapchain_support(device, context.temp_allocator)
			if result != .SUCCESS {
				log.infof("vulkan: query swapchain support failure: %v", result)
				return 0
			}

			// Need at least a format and present mode.
			if len(support.formats) == 0 || len(support.presentModes) == 0 {
				log.info("vulkan: device does not support swapchain")
				return 0
			}
		}

		families := find_queue_families(device)
		if _, has_graphics := families.graphics.?; !has_graphics {
			log.info("vulkan: device does not have a graphics queue")
			return 0
		}
		if _, has_present := families.present.?; !has_present {
			log.info("vulkan: device does not have a presentation queue")
			return 0
		}

		// Favor GPUs.
		switch props.deviceType {
		case .DISCRETE_GPU:
			score += 300_000
		case .INTEGRATED_GPU:
			score += 200_000
		case .VIRTUAL_GPU:
			score += 100_000
		case .CPU, .OTHER:
		}
		log.infof("vulkan: scored %i based on device type %v", score, props.deviceType)

		// Maximum texture size.
		score += int(props.limits.maxImageDimension2D)
		log.infof(
			"vulkan: added the max 2D image dimensions (texture size) of %v to the score",
			props.limits.maxImageDimension2D,
		)
		return
	}

	count: u32
	vk.EnumeratePhysicalDevices(g_instance, &count, nil) or_return
	if count == 0 {log.panic("vulkan: no GPU found")}

	devices := make([]vk.PhysicalDevice, count, context.temp_allocator)
	vk.EnumeratePhysicalDevices(g_instance, &count, raw_data(devices)) or_return

	best_device_score := -1
	for device in devices {
		if score := score_physical_device(device); score > best_device_score {
			g_physical_device = device
			best_device_score = score
		}
	}

	if best_device_score <= 0 {
		log.panic("vulkan: no suitable GPU found")
	}
	return .SUCCESS
}

Queue_Family_Indices :: struct {
	graphics: Maybe(u32),
	present:  Maybe(u32),
}

find_queue_families :: proc(device: vk.PhysicalDevice) -> (ids: Queue_Family_Indices) {
	count: u32
	vk.GetPhysicalDeviceQueueFamilyProperties(device, &count, nil)

	families := make([]vk.QueueFamilyProperties, count, context.temp_allocator)
	vk.GetPhysicalDeviceQueueFamilyProperties(device, &count, raw_data(families))

	for family, i in families {
		if .GRAPHICS in family.queueFlags {
			ids.graphics = u32(i)
		}

		supported: b32
		vk.GetPhysicalDeviceSurfaceSupportKHR(device, u32(i), g_surface, &supported)
		if supported {
			ids.present = u32(i)
		}

		// Found all needed queues?
		_, has_graphics := ids.graphics.?
		_, has_present := ids.present.?
		if has_graphics && has_present {
			break
		}
	}

	return
}

Swapchain_Support :: struct {
	capabilities: vk.SurfaceCapabilitiesKHR,
	formats:      []vk.SurfaceFormatKHR,
	presentModes: []vk.PresentModeKHR,
}

query_swapchain_support :: proc(
	device: vk.PhysicalDevice,
	allocator := context.temp_allocator,
) -> (
	support: Swapchain_Support,
	result: vk.Result,
) {
	// NOTE: looks like a wrong binding with the third arg being a multipointer.
	vk.GetPhysicalDeviceSurfaceCapabilitiesKHR(device, g_surface, &support.capabilities) or_return

	{
		count: u32
		vk.GetPhysicalDeviceSurfaceFormatsKHR(device, g_surface, &count, nil) or_return

		support.formats = make([]vk.SurfaceFormatKHR, count, allocator)
		vk.GetPhysicalDeviceSurfaceFormatsKHR(device, g_surface, &count, raw_data(support.formats)) or_return
	}

	{
		count: u32
		vk.GetPhysicalDeviceSurfacePresentModesKHR(device, g_surface, &count, nil) or_return

		support.presentModes = make([]vk.PresentModeKHR, count, allocator)
		vk.GetPhysicalDeviceSurfacePresentModesKHR(device, g_surface, &count, raw_data(support.presentModes)) or_return
	}

	return
}

choose_swapchain_surface_format :: proc(formats: []vk.SurfaceFormatKHR) -> vk.SurfaceFormatKHR {
	for format in formats {
		if format.format == .B8G8R8A8_SRGB && format.colorSpace == .SRGB_NONLINEAR {
			return format
		}
	}

	// Fallback non optimal.
	return formats[0]
}

choose_swapchain_present_mode :: proc(modes: []vk.PresentModeKHR) -> vk.PresentModeKHR {
	// We would like mailbox for the best tradeoff between tearing and latency.
	for mode in modes {
		if mode == .MAILBOX {
			return .MAILBOX
		}
	}

	// As a fallback, fifo (basically vsync) is always available.
	return .FIFO
}

choose_swapchain_extent :: proc(capabilities: vk.SurfaceCapabilitiesKHR) -> vk.Extent2D {
	if capabilities.currentExtent.width != max(u32) {
		return capabilities.currentExtent
	}

	width, height := glfw.GetFramebufferSize(g_window)
	return(
		vk.Extent2D {
			width = clamp(u32(width), capabilities.minImageExtent.width, capabilities.maxImageExtent.width),
			height = clamp(u32(height), capabilities.minImageExtent.height, capabilities.maxImageExtent.height),
		} \
	)
}

glfw_error_callback :: proc "c" (code: i32, description: cstring) {
	context = g_ctx
	log.errorf("glfw: %i: %s", code, description)
}

vk_messenger_callback :: proc "system" (
	messageSeverity: vk.DebugUtilsMessageSeverityFlagsEXT,
	messageTypes: vk.DebugUtilsMessageTypeFlagsEXT,
	pCallbackData: ^vk.DebugUtilsMessengerCallbackDataEXT,
	pUserData: rawptr,
) -> b32 {
	context = g_ctx

	level: log.Level
	if .ERROR in messageSeverity {
		level = .Error
	} else if .WARNING in messageSeverity {
		level = .Warning
	} else if .INFO in messageSeverity {
		level = .Info
	} else {
		level = .Debug
	}

	log.logf(level, "vulkan[%v]: %s", messageTypes, pCallbackData.pMessage)
	return false
}

physical_device_extensions :: proc(
	device: vk.PhysicalDevice,
	allocator := context.temp_allocator,
) -> (
	exts: []vk.ExtensionProperties,
	res: vk.Result,
) {
	count: u32
	vk.EnumerateDeviceExtensionProperties(device, nil, &count, nil) or_return

	exts = make([]vk.ExtensionProperties, count, allocator)
	vk.EnumerateDeviceExtensionProperties(device, nil, &count, raw_data(exts)) or_return

	return
}

create_swapchain :: proc() {
	indices := find_queue_families(g_physical_device)

	// Setup swapchain.
	{
		support, result := query_swapchain_support(g_physical_device, context.temp_allocator)
		if result != .SUCCESS {
			log.panicf("vulkan: query swapchain failed: %v", result)
		}

		surface_format := choose_swapchain_surface_format(support.formats)
		present_mode := choose_swapchain_present_mode(support.presentModes)
		extent := choose_swapchain_extent(support.capabilities)

		g_swapchain_format = surface_format
		g_swapchain_extent = extent

		image_count := support.capabilities.minImageCount + 1
		if support.capabilities.maxImageCount > 0 && image_count > support.capabilities.maxImageCount {
			image_count = support.capabilities.maxImageCount
		}

		create_info := vk.SwapchainCreateInfoKHR {
			sType            = .SWAPCHAIN_CREATE_INFO_KHR,
			surface          = g_surface,
			minImageCount    = image_count,
			imageFormat      = surface_format.format,
			imageColorSpace  = surface_format.colorSpace,
			imageExtent      = extent,
			imageArrayLayers = 1,
			imageUsage       = {.COLOR_ATTACHMENT},
			preTransform     = support.capabilities.currentTransform,
			compositeAlpha   = {.OPAQUE},
			presentMode      = present_mode,
			clipped          = true,
		}

		if indices.graphics != indices.present {
			create_info.imageSharingMode = .CONCURRENT
			create_info.queueFamilyIndexCount = 2
			create_info.pQueueFamilyIndices = raw_data([]u32{indices.graphics.?, indices.present.?})
		}

		must(vk.CreateSwapchainKHR(g_device, &create_info, nil, &g_swapchain))
	}

	// Setup swapchain images.
	{
		count: u32
		must(vk.GetSwapchainImagesKHR(g_device, g_swapchain, &count, nil))

		g_swapchain_images = make([]vk.Image, count)
		g_swapchain_views = make([]vk.ImageView, count)
		must(vk.GetSwapchainImagesKHR(g_device, g_swapchain, &count, raw_data(g_swapchain_images)))

		for image, i in g_swapchain_images {
			create_info := vk.ImageViewCreateInfo {
				sType = .IMAGE_VIEW_CREATE_INFO,
				image = image,
				viewType = .D2,
				format = g_swapchain_format.format,
				subresourceRange = {aspectMask = {.COLOR}, levelCount = 1, layerCount = 1},
			}
			must(vk.CreateImageView(g_device, &create_info, nil, &g_swapchain_views[i]))
		}
	}
}

destroy_swapchain :: proc() {
	for view in g_swapchain_views {
		vk.DestroyImageView(g_device, view, nil)
	}
	delete(g_swapchain_views)
	delete(g_swapchain_images)
	vk.DestroySwapchainKHR(g_device, g_swapchain, nil)
}

create_framebuffers :: proc() {
	g_swapchain_frame_buffers = make([]vk.Framebuffer, len(g_swapchain_views))
	for view, i in g_swapchain_views {
		attachments := []vk.ImageView{view}

		frame_buffer := vk.FramebufferCreateInfo {
			sType           = .FRAMEBUFFER_CREATE_INFO,
			renderPass      = g_render_pass,
			attachmentCount = 1,
			pAttachments    = raw_data(attachments),
			width           = g_swapchain_extent.width,
			height          = g_swapchain_extent.height,
			layers          = 1,
		}
		must(vk.CreateFramebuffer(g_device, &frame_buffer, nil, &g_swapchain_frame_buffers[i]))
	}
}

destroy_framebuffers :: proc() {
	for frame_buffer in g_swapchain_frame_buffers {vk.DestroyFramebuffer(g_device, frame_buffer, nil)}
	delete(g_swapchain_frame_buffers)
}

recreate_swapchain :: proc() {
	// Don't do anything when minimized.
	for w, h := glfw.GetFramebufferSize(g_window); w == 0 || h == 0; w, h = glfw.GetFramebufferSize(g_window) {
		glfw.WaitEvents()

		// Handle closing while minimized.
		if glfw.WindowShouldClose(g_window) { break }
	}

	vk.DeviceWaitIdle(g_device)

	destroy_framebuffers()
	destroy_swapchain()

	create_swapchain()
	create_framebuffers()
}

create_shader_module :: proc(code: []byte) -> (module: vk.ShaderModule) {
	as_u32 := slice.reinterpret([]u32, code)

	create_info := vk.ShaderModuleCreateInfo {
		sType    = .SHADER_MODULE_CREATE_INFO,
		codeSize = len(code),
		pCode    = raw_data(as_u32),
	}
	must(vk.CreateShaderModule(g_device, &create_info, nil, &module))
	return
}

record_command_buffer :: proc(command_buffer: vk.CommandBuffer, image_index: u32) {
	begin_info := vk.CommandBufferBeginInfo {
		sType = .COMMAND_BUFFER_BEGIN_INFO,
	}
	must(vk.BeginCommandBuffer(command_buffer, &begin_info))

	clear_color := vk.ClearValue{}
	clear_color.color.float32 = g_background

	render_pass_info := vk.RenderPassBeginInfo {
		sType = .RENDER_PASS_BEGIN_INFO,
		renderPass = g_render_pass,
		framebuffer = g_swapchain_frame_buffers[image_index],
		renderArea = {extent = g_swapchain_extent},
		clearValueCount = 1,
		pClearValues = &clear_color,
	}
	vk.CmdBeginRenderPass(command_buffer, &render_pass_info, .INLINE)

	vk.CmdBindPipeline(command_buffer, .GRAPHICS, g_pipeline)

	viewport := vk.Viewport {
		width    = f32(g_swapchain_extent.width),
		height   = f32(g_swapchain_extent.height),
		maxDepth = 1.0,
	}
	vk.CmdSetViewport(command_buffer, 0, 1, &viewport)

	scissor := vk.Rect2D {
		extent = g_swapchain_extent,
	}
	vk.CmdSetScissor(command_buffer, 0, 1, &scissor)

	aspect := f32(g_swapchain_extent.width) / f32(g_swapchain_extent.height)
	push := Push_Constants{g_pan.x, g_pan.y, g_zoom, aspect}
	vk.CmdPushConstants(command_buffer, g_pipeline_layout, {.VERTEX}, 0, size_of(Push_Constants), &push)
	offset: vk.DeviceSize
	vk.CmdBindVertexBuffers(command_buffer, 0, 1, &g_vertex_buffer, &offset)
	vk.CmdDraw(command_buffer, u32(len(g_vertices)), 1, 0, 0)

	vk.CmdEndRenderPass(command_buffer)

	must(vk.EndCommandBuffer(command_buffer))
}

parse_arguments :: proc() -> (root, current, theme_file: string) {
	root = "."
	for i := 1; i < len(os.args); i += 1 {
		switch os.args[i] {
		case "--root":
			if i+1 < len(os.args) { i += 1; root = os.args[i] }
		case "--current":
			if i+1 < len(os.args) { i += 1; current = normalize_id(os.args[i]) }
		case "--theme-file":
			if i+1 < len(os.args) { i += 1; theme_file = os.args[i] }
		case:
			// A positional path is convenient when running the renderer by hand.
			if i == 1 { root = os.args[i] }
		}
	}
	return
}

append_triangle :: proc(vertices: ^[dynamic]Vertex, a, b, c: Vec2, color: [4]f32) {
	append(vertices,
		Vertex{a.x, a.y, color[0], color[1], color[2], color[3]},
		Vertex{b.x, b.y, color[0], color[1], color[2], color[3]},
		Vertex{c.x, c.y, color[0], color[1], color[2], color[3]},
	)
}

build_mesh :: proc(graph: ^Graph, current: string) -> [dynamic]Vertex {
	vertices := make([dynamic]Vertex, 0, len(graph.edges)*6 + len(graph.notes)*36)
	degrees := make([]int, len(graph.notes), context.temp_allocator)
	for edge in graph.edges { degrees[edge.from] += 1; degrees[edge.to] += 1 }

	// Links are thin transparent quads, emitted first so nodes stay crisp.
	for edge in graph.edges {
		a, b := graph.notes[edge.from].pos, graph.notes[edge.to].pos
		dx, dy := b.x-a.x, b.y-a.y
		length := math.sqrt(dx*dx + dy*dy)
		if length < 0.0001 { continue }
		width: f32 = 0.0022
		n := Vec2{-dy/length*width, dx/length*width}
		p0, p1 := Vec2{a.x+n.x,a.y+n.y}, Vec2{a.x-n.x,a.y-n.y}
		p2, p3 := Vec2{b.x+n.x,b.y+n.y}, Vec2{b.x-n.x,b.y-n.y}
		color := g_edge_color
		append_triangle(&vertices, p0, p1, p2, color)
		append_triangle(&vertices, p2, p1, p3, color)
	}

	segments := 14
	for note, i in graph.notes {
		radius: f32 = 0.011 + min(f32(degrees[i]), 12)*0.0011
		color := g_node_color
		if degrees[i] == 0 { color = g_muted_color }
		if len(current) > 0 && note.id == current {
			color = g_highlight_color
			radius *= 1.45
		}
		for segment in 0..<segments {
			a0 := f32(segment) / f32(segments) * 2*math.PI
			a1 := f32(segment+1) / f32(segments) * 2*math.PI
			p0 := Vec2{note.pos.x + math.cos(a0)*radius, note.pos.y + math.sin(a0)*radius}
			p1 := Vec2{note.pos.x + math.cos(a1)*radius, note.pos.y + math.sin(a1)*radius}
			append_triangle(&vertices, note.pos, p0, p1, color)
		}
	}
	return vertices
}

find_memory_type :: proc(bits: u32, wanted: vk.MemoryPropertyFlags) -> u32 {
	properties: vk.PhysicalDeviceMemoryProperties
	vk.GetPhysicalDeviceMemoryProperties(g_physical_device, &properties)
	for i: u32 = 0; i < properties.memoryTypeCount; i += 1 {
		if (bits & (u32(1) << i)) != 0 && wanted <= properties.memoryTypes[i].propertyFlags {
			return i
		}
	}
	log.panic("vulkan: no suitable host-visible memory type")
}

destroy_vertex_buffer :: proc() {
	if g_vertex_buffer != 0 {
		vk.DestroyBuffer(g_device, g_vertex_buffer, nil)
		g_vertex_buffer = {}
	}
	if g_vertex_memory != 0 {
		vk.FreeMemory(g_device, g_vertex_memory, nil)
		g_vertex_memory = {}
	}
}

hex_digit :: proc(value: byte) -> (u8, bool) {
	switch value {
	case '0'..='9': return value-'0', true
	case 'a'..='f': return value-'a'+10, true
	case 'A'..='F': return value-'A'+10, true
	}
	return 0, false
}

srgb_to_linear :: proc(value: f32) -> f32 {
	if value <= 0.04045 { return value / 12.92 }
	return math.pow((value + 0.055) / 1.055, 2.4)
}

parse_hex_color :: proc(text: string, alpha: f32 = 1.0) -> (color: [4]f32, ok: bool) {
	value := strings.trim_space(text)
	if strings.has_prefix(value, "#") { value = value[1:] }
	if len(value) != 6 { return }
	values: [3]u8
	for channel in 0..<3 {
		hi, hi_ok := hex_digit(value[channel*2])
		lo, lo_ok := hex_digit(value[channel*2+1])
		if !hi_ok || !lo_ok { return }
		values[channel] = hi*16+lo
	}
	color = {
		srgb_to_linear(f32(values[0])/255),
		srgb_to_linear(f32(values[1])/255),
		srgb_to_linear(f32(values[2])/255),
		alpha,
	}
	return color, true
}

load_theme :: proc(path: string) -> bool {
	if len(path) == 0 { return false }
	data, err := os.read_entire_file(path, context.temp_allocator)
	if err != nil { return false }
	colors := [5][4]f32{g_background, g_node_color, g_edge_color, g_muted_color, g_highlight_color}
	text := string(data)
	count := 0
	for line in strings.split_lines_iterator(&text) {
		if count >= len(colors) { break }
		alpha: f32 = 1
		if count == 2 { alpha = 0.42 }
		color, ok := parse_hex_color(line, alpha)
		if !ok { return false }
		colors[count] = color
		count += 1
	}
	if count != len(colors) { return false }
	changed := colors[0] != g_background || colors[1] != g_node_color ||
	           colors[2] != g_edge_color || colors[3] != g_muted_color ||
	           colors[4] != g_highlight_color
	g_background = colors[0]
	g_node_color = colors[1]
	g_edge_color = colors[2]
	g_muted_color = colors[3]
	g_highlight_color = colors[4]
	return changed
}

replace_vertex_data :: proc(vertices: [dynamic]Vertex) {
	must(vk.DeviceWaitIdle(g_device))
	destroy_vertex_buffer()
	delete(g_vertices)
	g_vertices = vertices
	create_vertex_buffer(g_vertices[:])
}

reload_theme_if_changed :: proc() {
	now := glfw.GetTime()
	if now < g_next_theme_scan { return }
	g_next_theme_scan = now + 0.25
	if load_theme(g_theme_file) {
		replace_vertex_data(build_mesh(&g_graph, g_current))
		log.info("synapse: updated colors from Neovim")
	}
}

vault_fingerprint :: proc(root: string) -> u64 {
	fingerprint: u64 = 0xcbf29ce484222325
	count: u64
	walker := os.walker_create(root)
	defer os.walker_destroy(&walker)
	for info in os.walker_walk(&walker) {
		if info.type == .Directory && is_ignored_directory(info.name) {
			os.walker_skip_dir(&walker)
			continue
		}
		if info.type != .Regular || !is_markdown_file_name(info.name) { continue }
		modified := u64(time.to_unix_nanoseconds(info.modification_time))
		file_hash := hash_string(info.fullpath) ~ u64(info.size) ~ modified
		// Order-independent combination keeps directory enumeration changes from
		// causing false reloads while still accounting for every Markdown file.
		fingerprint ~= file_hash + 0x9e3779b97f4a7c15 + (file_hash << 6) + (file_hash >> 2)
		count += 1
	}
	return fingerprint ~ (count * 0x100000001b3)
}

reload_graph_if_changed :: proc() {
	now := glfw.GetTime()
	if now < g_next_vault_scan { return }
	g_next_vault_scan = now + 0.5

	fingerprint := vault_fingerprint(g_root)
	if fingerprint == g_vault_fingerprint { return }

	graph, ok := load_graph(g_root)
	if !ok { return }
	layout_graph(&graph)
	vertices := build_mesh(&graph, g_current)

	// Command buffers may still refer to the old vertex buffer. Waiting here is
	// infrequent and lets us replace only GPU graph data, not the native window.
	replace_vertex_data(vertices)
	destroy_graph(&g_graph)
	g_graph = graph
	g_vault_fingerprint = fingerprint
	g_last_hovered = -2

	title := fmt.tprintf("Synapse — %d notes · %d links", len(g_graph.notes), len(g_graph.edges))
	glfw.SetWindowTitle(g_window, strings.clone_to_cstring(title, context.temp_allocator))
	log.infof("synapse: reloaded %d notes and %d links", len(g_graph.notes), len(g_graph.edges))
}

create_vertex_buffer :: proc(vertices: []Vertex) {
	size := vk.DeviceSize(len(vertices) * size_of(Vertex))
	// Vulkan does not permit zero-sized buffers; an empty vault still opens.
	if size == 0 { size = 4 }
	info := vk.BufferCreateInfo {
		sType = .BUFFER_CREATE_INFO,
		size = size,
		usage = {.VERTEX_BUFFER},
		sharingMode = .EXCLUSIVE,
	}
	must(vk.CreateBuffer(g_device, &info, nil, &g_vertex_buffer))
	requirements: vk.MemoryRequirements
	vk.GetBufferMemoryRequirements(g_device, g_vertex_buffer, &requirements)
	allocation := vk.MemoryAllocateInfo {
		sType = .MEMORY_ALLOCATE_INFO,
		allocationSize = requirements.size,
		memoryTypeIndex = find_memory_type(requirements.memoryTypeBits, {.HOST_VISIBLE, .HOST_COHERENT}),
	}
	must(vk.AllocateMemory(g_device, &allocation, nil, &g_vertex_memory))
	must(vk.BindBufferMemory(g_device, g_vertex_buffer, g_vertex_memory, 0))
	if len(vertices) > 0 {
		mapped: rawptr
		must(vk.MapMemory(g_device, g_vertex_memory, 0, size, {}, &mapped))
		mem.copy(mapped, raw_data(vertices), int(size))
		vk.UnmapMemory(g_device, g_vertex_memory)
	}
}

scroll_callback :: proc "c" (_: glfw.WindowHandle, _: f64, y: f64) {
	context = g_ctx
	g_zoom = clamp(g_zoom * math.pow(1.12, f32(y)), 0.25, 8.0)
}

handle_input :: proc() {
	if glfw.GetKey(g_window, glfw.KEY_ESCAPE) == glfw.PRESS {
		glfw.SetWindowShouldClose(g_window, true)
	}
	step := 0.018 / g_zoom
	if glfw.GetKey(g_window, glfw.KEY_A) == glfw.PRESS || glfw.GetKey(g_window, glfw.KEY_LEFT) == glfw.PRESS { g_pan.x += step }
	if glfw.GetKey(g_window, glfw.KEY_D) == glfw.PRESS || glfw.GetKey(g_window, glfw.KEY_RIGHT) == glfw.PRESS { g_pan.x -= step }
	if glfw.GetKey(g_window, glfw.KEY_W) == glfw.PRESS || glfw.GetKey(g_window, glfw.KEY_UP) == glfw.PRESS { g_pan.y -= step }
	if glfw.GetKey(g_window, glfw.KEY_S) == glfw.PRESS || glfw.GetKey(g_window, glfw.KEY_DOWN) == glfw.PRESS { g_pan.y += step }
	if glfw.GetKey(g_window, glfw.KEY_EQUAL) == glfw.PRESS { g_zoom = min(g_zoom*1.02, 8.0) }
	if glfw.GetKey(g_window, glfw.KEY_MINUS) == glfw.PRESS { g_zoom = max(g_zoom/1.02, 0.25) }
	if glfw.GetKey(g_window, glfw.KEY_0) == glfw.PRESS { g_zoom = 1; g_pan = {} }

	// Hovering a node exposes its title and repository-relative path without
	// introducing a font atlas dependency into the Vulkan renderer.
	x, y := glfw.GetCursorPos(g_window)
	w, h := glfw.GetWindowSize(g_window)
	if w <= 0 || h <= 0 { return }
	aspect := f32(w)/f32(h)
	world := Vec2{
		(f32(x)/f32(w)*2-1)*aspect/g_zoom - g_pan.x,
		(1-f32(y)/f32(h)*2)/g_zoom - g_pan.y,
	}
	hovered := -1
	best: f32 = 0.0012/(g_zoom*g_zoom)
	for note, i in g_graph.notes {
		dx, dy := note.pos.x-world.x, note.pos.y-world.y
		d2 := dx*dx+dy*dy
		if d2 < best { best = d2; hovered = i }
	}
	if hovered != g_last_hovered {
		if hovered >= 0 {
			title := fmt.tprintf("Synapse — %s  [%s]", g_graph.notes[hovered].title, g_graph.notes[hovered].id)
			glfw.SetWindowTitle(g_window, strings.clone_to_cstring(title, context.temp_allocator))
		} else {
			title := fmt.tprintf("Synapse — %d notes · %d links", len(g_graph.notes), len(g_graph.edges))
			glfw.SetWindowTitle(g_window, strings.clone_to_cstring(title, context.temp_allocator))
		}
		g_last_hovered = hovered
	}
}

byte_arr_str :: proc(arr: ^[$N]byte) -> string {
	return strings.truncate_to_byte(string(arr[:]), 0)
}

must :: proc(result: vk.Result, loc := #caller_location) {
	if result != .SUCCESS {
		log.panicf("vulkan failure %v", result, location = loc)
	}
}
