/*
 * nbinfo: load a Quadra network binary (.nb) on the card and print its
 * input/output tensor shapes and quantization. Needs init_rsrc first.
 * Build: cc -o nbinfo nbinfo.c -I/usr/local/include -L/usr/local/lib -lxcoder
 */
#include <stdio.h>
#include <stdlib.h>
#include <ni_device_api.h>

static const char *fmt_name[] = { "fp32", "fp16", "uint8", "int8", "uint16",
    "int16", "char", "bfp16", "int32", "uint32", "int64", "uint64", "fp64" };
static const char *q_name[] = { "none", "dfp", "affine" };

static void
print_layer(const char *dir, uint32_t i, const ni_network_layer_params_t *p)
{
	uint32_t d;

	printf("%s[%u] dims=%u sizes=", dir, i, p->num_of_dims);
	for (d = 0; d < p->num_of_dims && d < 6; d++)
		printf("%s%u", d ? "x" : "", p->sizes[d]);
	printf(" format=%s quant=%s",
	    (unsigned)p->data_format < 13 ? fmt_name[p->data_format] : "?",
	    (unsigned)p->quant_format < 3 ? q_name[p->quant_format] : "?");
	if (p->quant_format == NI_AI_BUFFER_QUANTIZE_DYNAMIC_FIXED_POINT)
		printf(" fixed_point_pos=%d", p->quant_data.dfp.fixed_point_pos);
	else if (p->quant_format == NI_AI_BUFFER_QUANTIZE_TF_ASYMM)
		printf(" scale=%g zero=%d", p->quant_data.affine.scale,
		    p->quant_data.affine.zeroPoint);
	printf("\n");
}

int
main(int argc, char **argv)
{
	ni_session_context_t ctx;
	ni_network_data_t net = { 0 };
	uint32_t i;
	int dev = argc > 2 ? atoi(argv[2]) : 0;

	if (argc < 2) {
		fprintf(stderr, "usage: nbinfo file.nb [devid]\n");
		return (1);
	}
	if (ni_device_session_context_init(&ctx) != NI_RETCODE_SUCCESS)
		return (1);
	ctx.hw_id = dev;
	ctx.device_type = NI_DEVICE_TYPE_AI;
	ctx.keep_alive_timeout = 10;
	if (ni_device_session_open(&ctx, NI_DEVICE_TYPE_AI) !=
	    NI_RETCODE_SUCCESS) {
		fprintf(stderr, "session open failed\n");
		return (1);
	}
	if (ni_ai_config_network_binary(&ctx, &net, argv[1]) !=
	    NI_RETCODE_SUCCESS) {
		fprintf(stderr, "config network binary failed\n");
		ni_device_session_close(&ctx, 1, NI_DEVICE_TYPE_AI);
		return (1);
	}
	printf("%s: inputs=%u outputs=%u\n", argv[1], net.input_num,
	    net.output_num);
	for (i = 0; i < net.input_num; i++)
		print_layer("in ", i, &net.linfo.in_param[i]);
	for (i = 0; i < net.output_num; i++)
		print_layer("out", i, &net.linfo.out_param[i]);
	ni_device_session_close(&ctx, 1, NI_DEVICE_TYPE_AI);
	ni_device_session_context_clear(&ctx);
	return (0);
}
